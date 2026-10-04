package com.borodutch.absplus

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.util.Base64
import androidx.media3.common.Player
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.min

/** like optString, but JSON null -> "" (optString returns the text "null") */
fun JSONObject.str(k: String): String = if (isNull(k)) "" else optString(k)

class Track(val ino: String, val ext: String, val size: Long, val duration: Double, val start: Double)

class Now(val item: String, val ep: String?, val title: String, val author: String, val tracks: List<Track>) {
    val key = if (ep == null) item else "$item/$ep"
    val duration = tracks.sumOf { it.duration }
    /** book time (s) -> (track index, offset ms) */
    fun at(t: Double): Pair<Int, Long> {
        val i = tracks.indexOfLast { it.start <= t }.coerceAtLeast(0)
        return i to ((t - tracks[i].start) * 1000).toLong()
    }

    fun json(): JSONObject = JSONObject().put("item", item).put("ep", ep).put("title", title).put("author", author).put("tracks", JSONArray().apply {
        tracks.forEach { put(JSONObject().put("ino", it.ino).put("ext", it.ext).put("size", it.size).put("duration", it.duration).put("start", it.start)) }
    })

    companion object {
        fun of(j: JSONObject): Now {
            val a = j.getJSONArray("tracks")
            return Now(j.getString("item"), j.str("ep").ifEmpty { null }, j.getString("title"), j.getString("author"), (0 until a.length()).map {
                a.getJSONObject(it).run { Track(getString("ino"), getString("ext"), getLong("size"), getDouble("duration"), getDouble("start")) }
            })
        }
    }
}

/** Anything shown as a tile/row: a library item, or a podcast episode when [ep] is set. */
class Card(val id: String, val title: String, val sub: String, val ep: String? = null) {
    val key = if (ep == null) id else "$id/$ep"
    fun json() = JSONObject().put("id", id).put("title", title).put("sub", sub).put("ep", ep)

    companion object {
        fun of(j: JSONObject) = Card(j.getString("id"), j.getString("title"), j.str("sub"), j.str("ep").ifEmpty { null })
        /** from a library item json (minified or expanded) */
        fun item(j: JSONObject): Card {
            val md = j.getJSONObject("media").getJSONObject("metadata")
            return Card(j.getString("id"), md.str("title"), md.str("authorName").ifEmpty { md.str("author") })
        }
    }
}

class Pos(val who: String, val time: Double, val at: Long)

class HttpErr(val code: Int) : IOException(when (code) { 401 -> "Unauthorized (401)"; 403 -> "Not allowed (403)"; else -> "HTTP $code" })
class StaleSession : IOException("Session changed")
class Expired : IOException("Session expired, please log in again")

/** Server API, accounts, downloads, progress. Everything lives in one SharedPreferences file. */
object Abs {
    lateinit var p: SharedPreferences
    lateinit var dir: File
    private lateinit var cacheDir: File
    var now: Now? = null
    // Selected only after successful login. Retained metadata contains no account state.
    @Volatile private var mediaServer: String? = null
    @Volatile var mediaEpoch = 0L
        private set
    private fun scope(s: String) = MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
    val mediaDir get() = File(dir, "servers/" + (mediaServer?.let(::scope) ?: "locked"))
    private fun retainedFile(path: String) = File(File(mediaDir, "metadata"), scope(path))
    private fun expanded(path: String) = path.startsWith("/api/items/") && path.endsWith("?expanded=1")
    internal val mediaLock = Any()
    class LoginAttempt internal constructor(val epoch: Long, val revision: Long) {
        @Volatile internal var cancelled = false
        fun cancel() = synchronized(mediaLock) { cancelled = true }
    }
    private var loginRevision = 0L
    fun beginLogin() = synchronized(mediaLock) { LoginAttempt(mediaEpoch, ++loginRevision) }
    fun checkSession(epoch: Long) { if (epoch != mediaEpoch || Thread.currentThread().isInterrupted) throw StaleSession() }
    fun <T> inSession(epoch: Long, work: () -> T): T = synchronized(mediaLock) { checkSession(epoch); work() }
    // Background work captures the session when scheduled, not when its thread finally runs.
    private val workEpoch = ThreadLocal<Long?>()
    fun <T> sessionWork(epoch: Long, work: () -> T): T {
        val prior = workEpoch.get()
        workEpoch.set(epoch)
        try { checkSession(epoch); return work() } finally { workEpoch.set(prior) }
    }
    private fun expectedEpoch() = workEpoch.get() ?: mediaEpoch
    private fun selectMedia(s: String?) { mediaServer = s; mediaEpoch++; dlChanged() }

    fun init(c: Context) {
        if (::p.isInitialized) return
        p = c.getSharedPreferences("abs", 0)
        dir = c.getExternalFilesDir(null)!!
        cacheDir = File(c.filesDir, "json").apply { mkdirs() }
        if (p.all.filterKeys { it.startsWith("acct:") }.values.any { runCatching { JSONObject(it as String).str("server") != server }.getOrDefault(true) }) {
            p.edit().clear().commit()
            cacheDir.listFiles()?.forEach { it.delete() }
        }
        if (me != null && server.isNotEmpty()) selectMedia(server)
        // Legacy unscoped bytes have no trustworthy owner. Keep them, but never adopt by ID.
        if (!p.contains("favq")) { // first run with server favorites: upload the local ones
            val q = JSONObject()
            JSONObject(p.getString("fav", "{}")).keys().forEach { q.put(it, true) }
            p.edit().putString("favq", q.toString()).apply()
        }
    }

    /** set when the server can't be reached; cleared by the next successful request */
    @Volatile var offline = false

    val server get() = p.getString("server", "")!!
    val me get() = p.getString("me", null)

    private fun http(method: String, path: String, body: String?, hdr: Map<String, String>, base: String, epoch: Long? = null): String {
        val c = URL(base + path).openConnection() as HttpURLConnection
        try {
            c.instanceFollowRedirects = false // credentials never follow a redirect to another origin
            c.requestMethod = method
            c.connectTimeout = 10_000
            c.readTimeout = 30_000
            hdr.forEach(c::setRequestProperty)
            if (body != null) {
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/json")
                c.outputStream.use { it.write(body.toByteArray()) }
            }
            val code = c.responseCode
            if (epoch != null) inSession(epoch) { offline = false }
            if (code >= 300) throw HttpErr(code)
            return c.inputStream.bufferedReader().use { it.readText() }
        } catch (e: IOException) {
            if (epoch != null) inSession(epoch) { if (e !is HttpErr && e !is StaleSession) offline = true }
            throw e
        } finally {
            c.disconnect()
        }
    }

    fun ping(): Boolean {
        val epoch = expectedEpoch()
        val base = inSession(epoch) { server }
        return runCatching { http("GET", "/ping", null, emptyMap(), base, epoch) }.isSuccess
    }

    // --- accounts: "acct:<username>" = {a: access token, r: refresh token}

    private fun credentials(u: JSONObject, base: String): Pair<String, String> {
        val name = u.getString("username")
        val access = u.str("accessToken").ifEmpty { u.str("token") }
        if (name.isBlank() || access.isEmpty()) throw IOException("Invalid login response")
        return name to JSONObject().put("a", access).put("r", u.str("refreshToken")).put("server", base).put("id", java.util.UUID.randomUUID().toString()).toString()
    }

    /** The candidate host is not published until validated credentials commit atomically. */
    fun login(url: String, user: String, pass: String, main: Boolean, attempt: LoginAttempt = beginLogin()): String {
        val base = if (main) url.trim().trimEnd('/').let { if ("://" in it) it else "https://$it" }
            else inSession(attempt.epoch) { if (me == null) throw Expired(); server }
        val parsed = URL(base)
        if (parsed.protocol !in listOf("http", "https") || parsed.host.isBlank() || parsed.userInfo != null || parsed.query != null || parsed.ref != null)
            throw IOException("Invalid server URL")
        fun check() {
            checkSession(attempt.epoch)
            if (attempt.cancelled || attempt.revision != loginRevision) throw StaleSession()
        }
        synchronized(mediaLock) { check() }
        val body = JSONObject().put("username", user.trim()).put("password", pass).toString()
        val r = try {
            http("POST", "/login", body, mapOf("x-return-tokens" to "true"), base)
        } catch (e: HttpErr) {
            synchronized(mediaLock) { check() }
            throw if (e.code == 401) IOException("Wrong username or password") else e
        }
        val (name, tok) = credentials(JSONObject(r).getJSONObject("user"), base)
        return synchronized(mediaLock) {
            check()
            if (main) {
                // Every main login is a new authorization generation, even same host/username.
                selectMedia(null)
                Dl.clear()
                cacheDir.listFiles()?.forEach { it.delete() }
                now = null; progress = emptyMap(); offline = false
                p.edit().clear().putString("server", base).putString("me", name).putString("acct:$name", tok).commit()
                selectMedia(base)
            } else if (name != me) {
                p.edit().putString("acct:$name", tok).commit()
            }
            name
        }
    }

    /** Capture the token's host before scheduling revocation; never consult the future server. */
    fun unlink(name: String) {
        val tok = synchronized(mediaLock) {
            if (name == me) return
            loginRevision++ // revocation also invalidates pending linked logins
            val tok = p.getString("acct:$name", null)
            val e = p.edit().remove("acct:$name")
            p.all.keys.filter { it.startsWith("share:") }.forEach { k -> e.putStringSet(k, p.getStringSet(k, emptySet())!! - name) }
            e.commit()
            tok?.let { JSONObject(it) }
        }
        if (tok != null && tok.str("server").isNotEmpty()) Thread {
            runCatching { http("POST", "/logout", "{}", mapOf("x-refresh-token" to tok.getString("r")), tok.getString("server")) }
        }.start()
    }

    fun accounts() = synchronized(mediaLock) {
        p.all.keys.filter { it.startsWith("acct:") }.map { it.drop(5) }.filter { it != me }.sorted()
    }

    fun logout() = synchronized(mediaLock) {
        selectMedia(null)
        loginRevision++
        Dl.clear()
        p.edit().clear().commit()
        cacheDir.listFiles()?.forEach { it.delete() }
        now = null; progress = emptyMap(); offline = false
    }

    private fun exp(t: String) = runCatching {
        JSONObject(String(Base64.decode(t.split('.')[1], Base64.URL_SAFE))).getLong("exp")
    }.getOrDefault(Long.MAX_VALUE / 1000)

    /** Refresh is serialized separately; logout/login never waits for the network. */
    private val refreshLock = Any()
    fun token(name: String = me ?: throw Expired(), force: Boolean = false, epoch: Long = expectedEpoch()): String = synchronized(refreshLock) {
        val stored = inSession(epoch) { p.getString("acct:$name", null) ?: throw Expired() }
        val a = JSONObject(stored)
        val base = a.str("server")
        inSession(epoch) { if (base.isEmpty() || base != server) throw Expired() }
        val t = a.getString("a")
        if (!force && exp(t) * 1000 - System.currentTimeMillis() > 60_000) return@synchronized t
        val r = try {
            http("POST", "/auth/refresh", "{}", mapOf("x-refresh-token" to a.getString("r")), base, epoch)
        } catch (e: HttpErr) {
            inSession(epoch) {
                if (p.getString("acct:$name", null) != stored) throw StaleSession()
                throw if (e.code == 401 && name == me) Expired() else e
            }
        }
        val (returnedName, tok) = credentials(JSONObject(r).getJSONObject("user"), base)
        inSession(epoch) {
            if (returnedName != name || p.getString("acct:$name", null) != stored) throw StaleSession()
            val rotated = JSONObject(tok).put("id", a.getString("id"))
            p.edit().putString("acct:$name", rotated.toString()).commit()
        }
        JSONObject(tok).getString("a")
    }

    fun api(method: String, path: String, body: JSONObject? = null, name: String = me ?: throw Expired(), allowed: () -> Boolean = { true }): String {
        val epoch = expectedEpoch()
        val (base, identity) = inSession(epoch) {
            if (!allowed()) throw StaleSession()
            server to JSONObject(p.getString("acct:$name", null) ?: throw Expired()).str("id")
        }
        val access = token(name, epoch = epoch)
        fun check() = inSession(epoch) {
            if (!allowed() || JSONObject(p.getString("acct:$name", null) ?: throw StaleSession()).str("id") != identity) throw StaleSession()
        }
        check()
        try {
            return http(method, path, body?.toString(), mapOf("Authorization" to "Bearer $access"), base, epoch).also { check() }
        } catch (e: HttpErr) {
            check()
            if (e.code != 401) throw e
            val refreshed = token(name, force = true, epoch = epoch)
            check()
            return http(method, path, body?.toString(), mapOf("Authorization" to "Bearer $refreshed"), base, epoch).also { check() }
        }
    }

    /** Media3 can retain an old URL after a session switch. Never attach the new token to it. */
    fun streamToken(uri: Uri, epoch: Long): String {
        val base = inSession(epoch) { server }
        if (!uri.toString().startsWith(base + "/api/")) throw StaleSession()
        return token(epoch = epoch).also { checkSession(epoch) }
    }

    // --- json cache, so screens render instantly and work offline

    private fun cacheFile(path: String) = File(cacheDir, path.replace(Regex("[^A-Za-z0-9]"), "_"))
    fun cached(path: String): String? = inSession(expectedEpoch()) {
        cacheFile(path).takeIf { it.exists() }?.readText()
            ?: if (mediaServer == server && me != null && expanded(path)) retainedFile(path).takeIf { it.exists() }?.readText() else null
    }

    fun get(path: String): String {
        val epoch = expectedEpoch()
        val data = api("GET", path)
        synchronized(mediaLock) {
            checkSession(epoch)
            cacheFile(path).writeText(data)
            if (mediaServer == server && me != null && expanded(path)) {
                val dst = retainedFile(path)
                dst.parentFile!!.mkdirs()
                val atomic = android.util.AtomicFile(dst)
                val stream = atomic.startWrite()
                try { stream.write(retainedItem(JSONObject(data)).toString().toByteArray()); atomic.finishWrite(stream) }
                catch (e: Exception) { atomic.failWrite(stream); throw e }
            }
        }
        return data
    }

    /** Explicit allowlist: no arbitrary server fields, user state or signed URLs survive logout. */
    private fun retainedItem(j: JSONObject): JSONObject {
        fun pick(o: JSONObject, vararg keys: String) = JSONObject().apply { keys.forEach { if (o.has(it)) put(it, o.get(it)) } }
        fun audio(o: JSONObject) = pick(o, "ino", "duration", "startOffset").put("metadata", pick(o.optJSONObject("metadata") ?: JSONObject(), "ext", "size"))
        val m = j.getJSONObject("media")
        val safe = JSONObject().put("metadata", pick(m.getJSONObject("metadata"), "title", "authorName", "author", "description"))
        m.optJSONArray("tracks")?.let { a -> safe.put("tracks", JSONArray().apply { for (i in 0 until a.length()) put(audio(a.getJSONObject(i))) }) }
        m.optJSONArray("episodes")?.let { a -> safe.put("episodes", JSONArray().apply {
            for (i in 0 until a.length()) { val e = a.getJSONObject(i); put(pick(e, "id", "title", "publishedAt").apply { e.optJSONObject("audioFile")?.let { put("audioFile", audio(it)) } }) }
        }) }
        return pick(j, "id", "mediaType").put("media", safe)
    }

    // --- tracks & downloads

    fun track(af: JSONObject, start: Double): Track {
        val m = af.getJSONObject("metadata")
        return Track(af.get("ino").toString(), m.str("ext"), m.optLong("size"), af.optDouble("duration", 0.0), start)
    }

    fun tracks(a: JSONArray) = (0 until a.length()).map { a.getJSONObject(it).let { t -> track(t, t.optDouble("startOffset", 0.0)) } }

    internal fun mediaFile(root: File, item: String, t: Track): File {
        require(item.isNotEmpty() && item !in setOf(".", "..") && '/' !in item && 92.toChar() !in item)
        val name = t.ino + t.ext
        require(name.isNotEmpty() && name !in setOf(".", "..") && '/' !in name && 92.toChar() !in name)
        return File(root, "audio/$item/$name")
    }
    fun file(item: String, t: Track) = mediaFile(mediaDir, item, t)
    fun done(item: String, t: Track) = file(item, t).isFile && file(item, t).length() == t.size
    fun uri(item: String, t: Track): Uri =
        if (done(item, t)) Uri.fromFile(file(item, t)) else Uri.parse("$server/api/items/$item/file/${t.ino}")

    private val dlMemo = java.util.concurrent.ConcurrentHashMap<String, Boolean>()
    fun dlChanged() = dlMemo.clear()

    /** book fully downloaded / podcast has a downloaded episode (judged from the item page's cached json) */
    fun downloaded(id: String) = dlMemo.getOrPut("$mediaEpoch:$id") {
        File(mediaDir, "audio/$id").exists() && runCatching {
            val m = JSONObject(cached("/api/items/$id?expanded=1")!!).getJSONObject("media")
            m.optJSONArray("tracks")?.let { a -> tracks(a).all { done(id, it) } } ?: m.getJSONArray("episodes").let { e ->
                (0 until e.length()).any { i -> e.getJSONObject(i).optJSONObject("audioFile")?.let { done(id, track(it, 0.0)) } == true }
            }
        }.getOrDefault(false)
    }

    /** Episode cards require that exact audio file; item cards keep the library semantics above. */
    fun downloaded(card: Card): Boolean {
        val ep = card.ep ?: return downloaded(card.id)
        return dlMemo.getOrPut(card.key) {
            runCatching {
                val episodes = JSONObject(cached("/api/items/${card.id}?expanded=1")!!).getJSONObject("media").getJSONArray("episodes")
                (0 until episodes.length()).map { episodes.getJSONObject(it) }.firstOrNull { it.str("id") == ep }
                    ?.optJSONObject("audioFile")?.let {
                        val t = track(it, 0.0)
                        file(card.id, t).isFile && done(card.id, t)
                    } == true
            }.getOrDefault(false)
        }
    }

    /** item folders that hold finished files (a download in progress also leaves "*.part" files) */
    fun downloads() = if (mediaServer == null || me == null) emptyList() else File(mediaDir, "audio").listFiles { f -> f.isDirectory && f.list()?.any { !it.endsWith(".part") } == true }?.toList() ?: emptyList()

    /** title/author from the item page's cached json */
    fun cachedCard(id: String) = runCatching { Card.item(JSONObject(cached("/api/items/$id?expanded=1")!!)) }.getOrElse { Card(id, "Unknown item", "") }

    fun removeAll(item: File) {
        if (item.parentFile != File(mediaDir, "audio")) return
        Dl.jobs.filter { it.n.item == item.name }.forEach { Dl.cancel(it.n) }
        item.listFiles()?.forEach { it.delete() }
        item.delete()
        dlChanged()
    }

    /** deletes [files] and their partial downloads */
    fun remove(files: List<File>) {
        files.forEach { it.delete(); File(it.path + ".part").delete() }
        files.firstOrNull()?.parentFile?.delete() // only succeeds once empty
    }

    // --- progress. Shared items ("share:<itemId>" = linked usernames) get every update pushed to those accounts too.

    fun shares(item: String): Set<String> = p.getStringSet("share:$item", emptySet())!!
    fun setShares(item: String, s: Set<String>) = inSession(expectedEpoch()) { p.edit().putStringSet("share:$item", s.intersect(accounts().toSet())).apply() }

    // --- what's playing, kept across app restarts

    fun saveNow(n: Now) = inSession(expectedEpoch()) { p.edit().putString("now", n.json().toString()).apply() }

    fun loadNow() = runCatching { Now.of(JSONObject(p.getString("now", null)!!)) }.getOrNull()

    fun pos(pl: Player, n: Now) = (n.tracks.getOrNull(pl.currentMediaItemIndex)?.start ?: 0.0) + pl.currentPosition / 1000.0

    private fun remote(name: String, key: String) = runCatching {
        val j = JSONObject(api("GET", "/api/me/progress/$key", name = name))
        Pos(name, if (j.optBoolean("isFinished")) 0.0 else j.optDouble("currentTime", 0.0), j.optLong("lastUpdate"))
    }.getOrNull()

    /** First = where this account should resume; the rest = linked accounts that listened more recently elsewhere. */
    fun positions(n: Now): List<Pos> = sessionWork(expectedEpoch()) {
        val local = p.getString("pos:${n.key}", null)?.split(',')?.let { Pos("You", it[0].toDouble(), it[1].toLong()) }
        val mine = listOfNotNull(local, me?.let { remote(it, n.key) }?.let { Pos("You", it.time, it.at) })
            .maxByOrNull { it.at } ?: Pos("You", 0.0, 0)
        listOf(mine) + shares(n.item).mapNotNull { remote(it, n.key) }
            .filter { it.at > mine.at && abs(it.time - mine.time) > 30 }
    }

    /** latest known progress per key, from /api/me plus our own pushes */
    @Volatile var progress: Map<String, JSONObject> = emptyMap()

    fun setMe(j: JSONObject) = inSession(expectedEpoch()) {
        val a = j.getJSONArray("mediaProgress")
        progress = (0 until a.length()).map { a.getJSONObject(it) }.associateBy {
            if (it.isNull("episodeId")) it.getString("libraryItemId") else it.getString("libraryItemId") + "/" + it.getString("episodeId")
        }
        syncFavs(j.optJSONArray("bookmarks") ?: JSONArray())
    }

    /** 0..1, or null if never started */
    fun pct(key: String) = progress[key]?.let { if (it.optBoolean("isFinished")) 1.0 else it.optDouble("progress", 0.0) }

    fun push(n: Now, pos: Double, finished: Boolean, epoch: Long = expectedEpoch()) = sessionWork(epoch) {
        inSession(epoch) {
            progress = progress + (n.key to JSONObject().put("currentTime", pos).put("progress", if (finished) 1.0 else pos / n.duration).put("isFinished", finished))
            p.edit().putString("pos:${n.key}", "$pos,${System.currentTimeMillis()}").apply()
        }
        val b = JSONObject().put("currentTime", pos).put("duration", n.duration)
            .put("progress", if (n.duration > 0) min(1.0, pos / n.duration) else 0.0)
        // only send isFinished=true: the server ignores "progress" when isFinished is present, and false would un-finish
        if (finished) b.put("isFinished", true)
        for (a in listOfNotNull(me) + shares(n.item)) runCatching { api("PATCH", "/api/me/progress/${n.key}", b, a) }
    }

    // --- favorites: a per-user bookmark titled FAV on the item, so they sync across devices and work for podcasts too.
    // "fav" = local mirror {id: card} for instant display, "favq" = {id: on/off} changes not yet on the server.

    private const val FAV = "♥ Favorite"
    private const val FAV_T = 0.001 // odd time so a real 0:00 bookmark is never touched

    fun favs(): List<Card> = JSONObject(p.getString("fav", "{}")).let { o -> o.keys().asSequence().map { Card.of(o.getJSONObject(it)) }.toList().reversed() }
    fun isFav(id: String) = JSONObject(p.getString("fav", "{}")).has(id)

    fun toggleFav(c: Card): Boolean = inSession(expectedEpoch()) {
        val o = JSONObject(p.getString("fav", "{}"))
        val on = o.remove(c.id) == null
        if (on) o.put(c.id, c.json())
        val q = JSONObject(p.getString("favq", "{}")).put(c.id, on)
        p.edit().putString("fav", o.toString()).putString("favq", q.toString()).apply()
        on
    }

    /** Uploads queued favorite changes; call off the main thread. */
    fun pushFavs(epoch: Long = expectedEpoch()) = sessionWork(epoch) {
        for (id in JSONObject(p.getString("favq", "{}")).keys().asSequence().toList()) {
            val on = inSession(epoch) { JSONObject(p.getString("favq", "{}")).optBoolean(id) }
            val r = runCatching {
                if (on) api("POST", "/api/me/item/$id/bookmark", JSONObject().put("time", FAV_T).put("title", FAV))
                else api("DELETE", "/api/me/item/$id/bookmark/$FAV_T")
            }
            val gone = r.exceptionOrNull().let { it is HttpErr && it.code in 400..499 } // e.g. already removed
            if (r.isSuccess || gone) inSession(epoch) {
                val q = JSONObject(p.getString("favq", "{}"))
                if (q.optBoolean(id) == on) q.remove(id) // unless toggled again meanwhile
                p.edit().putString("favq", q.toString()).apply()
            }
        }
    }

    /** server favorites + changes not uploaded yet -> local mirror (cards for new ids get filled in by [fillFav]) */
    private fun syncFavs(bookmarks: JSONArray) {
        val q = JSONObject(p.getString("favq", "{}"))
        val server = (0 until bookmarks.length()).map { bookmarks.getJSONObject(it) }.filter { it.str("title") == FAV }.map { it.getString("libraryItemId") }
        val ids = (server + q.keys().asSequence().filter { q.getBoolean(it) }).toSet() - q.keys().asSequence().filter { !q.getBoolean(it) }.toSet()
        val old = JSONObject(p.getString("fav", "{}"))
        val o = JSONObject()
        old.keys().forEach { if (it in ids) o.put(it, old.get(it)) }
        ids.filter { !o.has(it) }.forEach { o.put(it, Card(it, "", "").json()) }
        p.edit().putString("fav", o.toString()).apply()
        if (q.length() > 0) { val epoch = mediaEpoch; Thread { runCatching { pushFavs(epoch) } }.start() }
    }

    /** title/author for a favorite added on another device; call off the main thread */
    fun fillFav(id: String) {
        val epoch = expectedEpoch()
        val c = Card.item(JSONObject(get("/api/items/$id")))
        inSession(epoch) {
            val o = JSONObject(p.getString("fav", "{}"))
            if (o.has(id)) p.edit().putString("fav", o.put(id, c.json()).toString()).apply()
        }
    }

    fun history(): List<Pair<Card, Long>> = JSONArray(p.getString("hist", "[]")).let { a ->
        (0 until a.length()).map { a.getJSONObject(it).let { j -> Card.of(j) to j.getLong("at") } }
    }

    fun addHistory(n: Now) = inSession(expectedEpoch()) {
        val c = Card(n.item, n.title, n.author, n.ep)
        val a = JSONArray().put(c.json().put("at", System.currentTimeMillis()))
        history().filter { it.first.key != c.key }.take(49).forEach { (h, at) -> a.put(h.json().put("at", at)) }
        p.edit().putString("hist", a.toString()).apply()
    }

    fun fmt(s: Double) = (s.toLong()).let { "%d:%02d:%02d".format(it / 3600, it / 60 % 60, it % 60) }
}
