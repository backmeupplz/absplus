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
class Expired : IOException("Session expired, please log in again")

/** Server API, accounts, downloads, progress. Everything lives in one SharedPreferences file. */
object Abs {
    lateinit var p: SharedPreferences
    lateinit var dir: File
    private lateinit var cacheDir: File
    var now: Now? = null

    fun init(c: Context) {
        if (::p.isInitialized) return
        p = c.getSharedPreferences("abs", 0)
        dir = c.getExternalFilesDir(null)!!
        cacheDir = File(c.filesDir, "json").apply { mkdirs() }
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

    private fun http(method: String, path: String, body: String?, hdr: Map<String, String>): String {
        val c = URL(server + path).openConnection() as HttpURLConnection
        try {
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
            offline = false
            if (code >= 400) throw HttpErr(code)
            return c.inputStream.bufferedReader().use { it.readText() }
        } catch (e: IOException) {
            if (e !is HttpErr) offline = true
            throw e
        } finally {
            c.disconnect()
        }
    }

    fun ping() = runCatching { http("GET", "/ping", null, emptyMap()) }.isSuccess

    // --- accounts: "acct:<username>" = {a: access token, r: refresh token}

    private fun save(u: JSONObject): String {
        val name = u.getString("username")
        val tok = JSONObject().put("a", u.str("accessToken").ifEmpty { u.str("token") }).put("r", u.str("refreshToken"))
        p.edit().putString("acct:$name", tok.toString()).commit()
        return name
    }

    /** Logs in; main = the account this app runs as, otherwise a linked account for progress sharing. */
    fun login(url: String, user: String, pass: String, main: Boolean): String {
        if (main) {
            val s = url.trim().trimEnd('/')
            p.edit().putString("server", if ("://" in s) s else "https://$s").commit()
        }
        val body = JSONObject().put("username", user.trim()).put("password", pass).toString()
        val r = try {
            http("POST", "/login", body, mapOf("x-return-tokens" to "true"))
        } catch (e: HttpErr) {
            throw if (e.code == 401) IOException("Wrong username or password") else e
        }
        val name = save(JSONObject(r).getJSONObject("user"))
        if (main) p.edit().putString("me", name).commit()
        return name
    }

    /** Forgets a linked account: its tokens, its shares, and its server session. */
    fun unlink(name: String) {
        val tok = p.getString("acct:$name", null)
        val e = p.edit().remove("acct:$name")
        p.all.keys.filter { it.startsWith("share:") }.forEach { k -> e.putStringSet(k, p.getStringSet(k, emptySet())!! - name) }
        e.apply()
        tok?.let { Thread { runCatching { http("POST", "/logout", "{}", mapOf("x-refresh-token" to JSONObject(it).getString("r"))) } }.start() }
    }

    fun accounts() = p.all.keys.filter { it.startsWith("acct:") }.map { it.drop(5) }.filter { it != me }.sorted()

    fun logout() {
        Dl.clear()
        p.edit().clear().commit()
        cacheDir.listFiles()?.forEach { it.delete() }
        now = null
    }

    private fun exp(t: String) = runCatching {
        JSONObject(String(Base64.decode(t.split('.')[1], Base64.URL_SAFE))).getLong("exp")
    }.getOrDefault(Long.MAX_VALUE / 1000)

    /** A valid access token for [name], refreshing it if it's about to expire. */
    @Synchronized
    fun token(name: String = me ?: throw Expired()): String {
        val a = JSONObject(p.getString("acct:$name", null) ?: throw Expired())
        val t = a.getString("a")
        if (exp(t) * 1000 - System.currentTimeMillis() > 60_000) return t
        val r = try {
            http("POST", "/auth/refresh", "{}", mapOf("x-refresh-token" to a.getString("r")))
        } catch (e: HttpErr) {
            throw if (e.code == 401 && name == me) Expired() else e
        }
        save(JSONObject(r).getJSONObject("user"))
        return JSONObject(p.getString("acct:$name", null)!!).getString("a")
    }

    fun api(method: String, path: String, body: JSONObject? = null, name: String = me ?: throw Expired()) =
        http(method, path, body?.toString(), mapOf("Authorization" to "Bearer " + token(name)))

    // --- json cache, so screens render instantly and work offline

    private fun cacheFile(path: String) = File(cacheDir, path.replace(Regex("[^A-Za-z0-9]"), "_"))
    fun cached(path: String) = cacheFile(path).takeIf { it.exists() }?.readText()
    fun get(path: String, validate: (String) -> Unit = {}): String {
        val owner = server to me
        return api("GET", path).also {
            validateCachedResponse(path, JSONObject(it))
            validate(it)
            if (owner == (server to me)) cacheFile(path).writeText(it)
        }
    }

    /** Validate every field required by cached-response consumers before replacing a good snapshot.
     * Keep this side-effect-free: UI rendering and setMe mutate view/preferences on the main thread.
     */
    internal fun validateCachedResponse(path: String, j: JSONObject) {
        fun objects(a: JSONArray, check: (JSONObject) -> Unit) {
            for (i in 0 until a.length()) check(a.getJSONObject(i))
        }
        fun card(item: JSONObject) { Card.item(item) }
        val route = path.substringBefore('?')
        when {
            route == "/api/me" -> {
                objects(j.getJSONArray("mediaProgress")) {
                    it.getString("libraryItemId")
                    if (!it.isNull("episodeId")) it.getString("episodeId")
                }
                objects(j.optJSONArray("bookmarks") ?: JSONArray()) {
                    if (it.str("title") == FAV) it.getString("libraryItemId")
                }
            }
            route == "/api/me/items-in-progress" -> objects(j.getJSONArray("libraryItems")) {
                card(it)
                it.optJSONObject("recentEpisode")?.getString("id")
            }
            route == "/api/libraries" -> objects(j.getJSONArray("libraries")) {
                it.getString("id"); it.getString("name")
            }
            route.startsWith("/api/libraries/") && route.endsWith("/items") -> objects(j.getJSONArray("results"), ::card)
            route.startsWith("/api/libraries/") && route.endsWith("/series") -> objects(j.getJSONArray("results")) {
                it.getString("name"); objects(it.getJSONArray("books"), ::card)
            }
            route.startsWith("/api/items/") -> {
                card(j)
                if (path.substringAfter('?', "").split('&').contains("expanded=1")) {
                    val media = j.getJSONObject("media")
                    when (j.getString("mediaType")) {
                        "book" -> tracks(media.getJSONArray("tracks"))
                        "podcast" -> objects(media.getJSONArray("episodes")) {
                            if (it.has("audioFile")) { it.getString("id"); track(it.getJSONObject("audioFile"), 0.0) }
                        }
                        else -> error("Unsupported media type")
                    }
                }
            }
            else -> error("No cached response schema for $route")
        }
    }

    // --- tracks & downloads

    fun track(af: JSONObject, start: Double): Track {
        val m = af.getJSONObject("metadata")
        return Track(af.get("ino").toString(), m.str("ext"), m.optLong("size"), af.optDouble("duration", 0.0), start)
    }

    fun tracks(a: JSONArray) = (0 until a.length()).map { a.getJSONObject(it).let { t -> track(t, t.optDouble("startOffset", 0.0)) } }

    fun file(item: String, t: Track) = File(dir, "$item/${t.ino}${t.ext}")
    fun done(item: String, t: Track) = file(item, t).length() == t.size
    fun uri(item: String, t: Track): Uri =
        if (done(item, t)) Uri.fromFile(file(item, t)) else Uri.parse("$server/api/items/$item/file/${t.ino}")

    private val dlMemo = HashMap<String, Boolean>()
    fun dlChanged() = dlMemo.clear()

    /** book fully downloaded / podcast has a downloaded episode (judged from the item page's cached json) */
    fun downloaded(id: String) = dlMemo.getOrPut(id) {
        File(dir, id).exists() && runCatching {
            val m = JSONObject(cached("/api/items/$id?expanded=1")!!).getJSONObject("media")
            m.optJSONArray("tracks")?.let { a -> a.length() > 0 && tracks(a).all { file(id, it).isFile && done(id, it) } } ?: m.getJSONArray("episodes").let { e ->
                (0 until e.length()).any { i -> e.getJSONObject(i).optJSONObject("audioFile")?.let {
                    val t = track(it, 0.0)
                    file(id, t).isFile && done(id, t)
                } == true }
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
    fun downloads() = dir.listFiles { f -> f.isDirectory && f.list()?.any { !it.endsWith(".part") } == true }?.toList() ?: emptyList()

    /** title/author from the item page's cached json */
    fun cachedCard(id: String) = runCatching { Card.item(JSONObject(cached("/api/items/$id?expanded=1")!!)) }.getOrElse { Card(id, "Unknown item", "") }

    fun removeAll(item: File) {
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
    fun setShares(item: String, s: Set<String>) = p.edit().putStringSet("share:$item", s).apply()

    // --- what's playing, kept across app restarts

    fun saveNow(n: Now) = p.edit().putString("now", n.json().toString()).apply()

    fun loadNow() = runCatching { Now.of(JSONObject(p.getString("now", null)!!)) }.getOrNull()

    fun pos(pl: Player, n: Now) = (n.tracks.getOrNull(pl.currentMediaItemIndex)?.start ?: 0.0) + pl.currentPosition / 1000.0

    private fun remote(name: String, key: String) = runCatching {
        val j = JSONObject(api("GET", "/api/me/progress/$key", name = name))
        Pos(name, if (j.optBoolean("isFinished")) 0.0 else j.optDouble("currentTime", 0.0), j.optLong("lastUpdate"))
    }.getOrNull()

    /** First = where this account should resume; the rest = linked accounts that listened more recently elsewhere. */
    fun positions(n: Now): List<Pos> {
        val local = p.getString("pos:${n.key}", null)?.split(',')?.let { Pos("You", it[0].toDouble(), it[1].toLong()) }
        val mine = listOfNotNull(local, me?.takeUnless { offline }?.let { remote(it, n.key) }?.let { Pos("You", it.time, it.at) })
            .maxByOrNull { it.at } ?: Pos("You", 0.0, 0)
        return listOf(mine) + (if (offline) emptySet() else shares(n.item)).mapNotNull { remote(it, n.key) }
            .filter { it.at > mine.at && abs(it.time - mine.time) > 30 }
    }

    /** latest known progress per key, from /api/me plus our own pushes */
    @Volatile var progress: Map<String, JSONObject> = emptyMap()

    fun setMe(j: JSONObject) {
        val a = j.getJSONArray("mediaProgress")
        progress = (0 until a.length()).map { a.getJSONObject(it) }.associateBy {
            if (it.isNull("episodeId")) it.getString("libraryItemId") else it.getString("libraryItemId") + "/" + it.getString("episodeId")
        }
        syncFavs(j.optJSONArray("bookmarks") ?: JSONArray())
    }

    /** 0..1, or null if never started */
    fun pct(key: String) = progress[key]?.let { if (it.optBoolean("isFinished")) 1.0 else it.optDouble("progress", 0.0) }

    fun push(n: Now, pos: Double, finished: Boolean) {
        progress = progress + (n.key to JSONObject().put("currentTime", pos).put("progress", if (finished) 1.0 else pos / n.duration).put("isFinished", finished))
        p.edit().putString("pos:${n.key}", "$pos,${System.currentTimeMillis()}").apply()
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

    @Synchronized
    fun toggleFav(c: Card): Boolean {
        val o = JSONObject(p.getString("fav", "{}"))
        val on = o.remove(c.id) == null
        if (on) o.put(c.id, c.json())
        val q = JSONObject(p.getString("favq", "{}")).put(c.id, on)
        p.edit().putString("fav", o.toString()).putString("favq", q.toString()).apply()
        return on
    }

    /** Uploads queued favorite changes; call off the main thread. */
    fun pushFavs() {
        for (id in JSONObject(p.getString("favq", "{}")).keys().asSequence().toList()) {
            val on = synchronized(this) { JSONObject(p.getString("favq", "{}")).optBoolean(id) }
            val r = runCatching {
                if (on) api("POST", "/api/me/item/$id/bookmark", JSONObject().put("time", FAV_T).put("title", FAV))
                else api("DELETE", "/api/me/item/$id/bookmark/$FAV_T")
            }
            val gone = r.exceptionOrNull().let { it is HttpErr && it.code in 400..499 } // e.g. already removed
            if (r.isSuccess || gone) synchronized(this) {
                val q = JSONObject(p.getString("favq", "{}"))
                if (q.optBoolean(id) == on) q.remove(id) // unless toggled again meanwhile
                p.edit().putString("favq", q.toString()).apply()
            }
        }
    }

    /** server favorites + changes not uploaded yet -> local mirror (cards for new ids get filled in by [fillFav]) */
    @Synchronized
    private fun syncFavs(bookmarks: JSONArray) {
        val q = JSONObject(p.getString("favq", "{}"))
        val server = (0 until bookmarks.length()).map { bookmarks.getJSONObject(it) }.filter { it.str("title") == FAV }.map { it.getString("libraryItemId") }
        val ids = (server + q.keys().asSequence().filter { q.getBoolean(it) }).toSet() - q.keys().asSequence().filter { !q.getBoolean(it) }.toSet()
        val old = JSONObject(p.getString("fav", "{}"))
        val o = JSONObject()
        old.keys().forEach { if (it in ids) o.put(it, old.get(it)) }
        ids.filter { !o.has(it) }.forEach { o.put(it, Card(it, "", "").json()) }
        p.edit().putString("fav", o.toString()).apply()
        if (q.length() > 0) Thread { pushFavs() }.start()
    }

    /** title/author for a favorite added on another device; call off the main thread */
    @Synchronized
    fun fillFav(id: String) {
        fillFavCard(Card.item(JSONObject(get("/api/items/$id"))))
    }

    @Synchronized
    fun fillFavCard(c: Card) {
        val id = c.id
        val o = JSONObject(p.getString("fav", "{}"))
        if (o.has(id)) p.edit().putString("fav", o.put(id, c.json()).toString()).apply()
    }

    fun history(): List<Pair<Card, Long>> = JSONArray(p.getString("hist", "[]")).let { a ->
        (0 until a.length()).map { a.getJSONObject(it).let { j -> Card.of(j) to j.getLong("at") } }
    }

    fun addHistory(n: Now) {
        val c = Card(n.item, n.title, n.author, n.ep)
        val a = JSONArray().put(c.json().put("at", System.currentTimeMillis()))
        history().filter { it.first.key != c.key }.take(49).forEach { (h, at) -> a.put(h.json().put("at", at)) }
        p.edit().putString("hist", a.toString()).apply()
    }

    fun fmt(s: Double) = (s.toLong()).let { "%d:%02d:%02d".format(it / 3600, it / 60 % 60, it % 60) }
}
