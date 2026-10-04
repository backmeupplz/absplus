package com.borodutch.absplus

import android.content.SharedPreferences
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Durable latest value per recipient/title. Episode keys include the parent title; no tokens.
 * ponytail: one serial replay lane; split only if multiple servers become supported.
 */
internal class ProgressSync(
    private val prefs: SharedPreferences,
    private val request: (String, String, JSONObject?, String, () -> Boolean) -> String,
    private val clock: () -> Long = System::currentTimeMillis,
    private val automatic: Boolean = true,
) {
    private val lock = Any()
    private val lane = Any()
    private val executor = if (automatic) Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "progress-replay").apply { isDaemon = true } } else null
    private var scheduled: ScheduledFuture<*>? = null
    private var closed = false
    private var mirror: Map<String, JSONObject> = emptyMap()
    private fun journal() = JSONObject(prefs.getString("progressJournal", "{}")!!)
    private fun entries(j: JSONObject) = j.keys().asSequence().map { it to j.getJSONObject(it) }.toList()
    private fun owner() = prefs.getString("me", null)
    private fun server() = prefs.getString("server", "")
    private fun valid(e: JSONObject): Boolean {
        val name = e.getString("name")
        return e.getString("server") == server() && e.getString("owner") == owner() &&
            prefs.contains("acct:$name") && (name == owner() || name in prefs.getStringSet("share:" + e.getString("item"), emptySet())!!)
    }
    private fun store(j: JSONObject) {
        check(prefs.edit().putString("progressJournal", j.toString()).commit()) { "Could not save listening progress" }
        mirror = entries(j).map { it.second }.filter { valid(it) && it.getString("name") == owner() }
            .associate { it.getString("key") to it.getJSONObject("value") }
    }

    init { prune(); wake() }

    fun close() = synchronized(lock) { closed = true; scheduled?.cancel(false); executor?.shutdownNow(); Unit }

    fun prune() = synchronized(lock) {
        val j = journal()
        entries(j).filter { !valid(it.second) }.forEach { j.remove(it.first) }
        store(j)
    }

    /** Synchronous at the playback event: persisted before network work is scheduled. */
    fun record(n: Now, position: Double, finished: Boolean, intentionalPlayback: Boolean = false) = synchronized(lock) {
        if (closed || !position.isFinite() || !n.duration.isFinite()) return@synchronized
        val me = owner() ?: return@synchronized
        if (!prefs.contains("acct:$me")) return@synchronized
        val j = journal()
        val old = entries(j).map { it.second }.filter { valid(it) && it.getString("name") == me && it.getString("key") == n.key }
        val at = maxOf(clock(), (old.maxOfOrNull { it.getJSONObject("value").getLong("lastUpdate") } ?: 0) + 1)
        // Passive restore/pause callbacks retain completion; actual playback starts a reread.
        val done = finished || (!intentionalPlayback && old.any { it.getJSONObject("value").optBoolean("isFinished") })
        val pos = position.coerceIn(0.0, n.duration.coerceAtLeast(0.0))
        val value = JSONObject().put("currentTime", pos).put("duration", n.duration)
            .put("progress", if (done) 1.0 else if (n.duration > 0) pos / n.duration else 0.0)
            .put("isFinished", done).put("lastUpdate", at)
        val recipients = (listOf(me) + prefs.getStringSet("share:" + n.item, emptySet())!!).distinct()
        recipients.filter { prefs.contains("acct:$it") }.forEach { name ->
            val id = org.json.JSONArray(listOf(server(), me, name, n.key)).toString()
            val previous = j.optJSONObject(id)
            val e = JSONObject().put("server", server()).put("owner", me).put("name", name)
                .put("item", n.item).put("key", n.key).put("value", value).put("dirty", true)
                .put("tries", previous?.optInt("tries") ?: 0).put("next", previous?.optLong("next") ?: 0)
            previous?.optJSONObject("sent")?.let { e.put("sent", it) }
            previous?.optJSONObject("ack")?.let { e.put("ack", it) }
            j.put(id, e)
        }
        store(j)
        wake()
    }

    fun local(): Map<String, JSONObject> = synchronized(lock) { if (closed) emptyMap() else mirror }

    /** Merge server reads without erasing newer offline progress or finished state. */
    fun observe(key: String, value: JSONObject): JSONObject = synchronized(lock) {
        val j = journal()
        val own = entries(j).firstOrNull { valid(it.second) && it.second.getString("name") == owner() && it.second.getString("key") == key }
        if (own != null) {
            val e = own.second
            val local = e.getJSONObject("value")
            // Resolve an uncertain write once. Later same-payload writes must match this
            // exact timestamp rather than borrowing an indefinitely retained sent payload.
            if (matches(value, e.optJSONObject("sent"))) {
                e.put("ack", value)
                e.remove("sent")
                store(j)
            }
            if (value.optLong("lastUpdate") <= local.optLong("lastUpdate") || acknowledged(value, e)) return@synchronized local
            e.put("value", value).put("dirty", false)
            e.remove("sent")
            e.remove("ack")
            store(j)
        }
        value
    }

    private fun matches(a: JSONObject, b: JSONObject?) = b != null &&
        a.optDouble("currentTime", -1.0) == b.optDouble("currentTime", -2.0) && a.optBoolean("isFinished") == b.optBoolean("isFinished")

    private fun acknowledged(remote: JSONObject, entry: JSONObject): Boolean {
        val ack = entry.optJSONObject("ack")
        return (ack != null && matches(remote, ack) && remote.optLong("lastUpdate") == ack.optLong("lastUpdate")) ||
            matches(remote, entry.optJSONObject("sent"))
    }

    /** Scheduler respects persisted exponential deadlines, even on reconnect or new playback. */
    fun wake(): Unit = synchronized(lock) {
        if (closed || executor == null) return@synchronized
        val next = entries(journal()).map { it.second }.filter { valid(it) && it.optBoolean("dirty") }.minOfOrNull { it.optLong("next") } ?: return@synchronized
        if (scheduled?.isDone == false) return@synchronized
        scheduled = executor.schedule({
            try { replay() } finally { synchronized(lock) { scheduled = null }; wake() }
        }, (next - clock()).coerceAtLeast(0), TimeUnit.MILLISECONDS)
    }

    /** One pass is exposed internally for deterministic controlled-server tests. */
    fun replay(): Unit = synchronized(lane) {
        val batch = synchronized(lock) {
            if (closed) return@synchronized emptyList<Pair<String, JSONObject>>()
            prune()
            entries(journal()).filter { it.second.optBoolean("dirty") && it.second.optLong("next") <= clock() }
        }
        for ((id, snapshot) in batch) {
            val value = snapshot.getJSONObject("value")
            fun current(): JSONObject? = synchronized(lock) {
                journal().optJSONObject(id)?.takeIf { !closed && valid(it) && it.optBoolean("dirty") && it.getJSONObject("value").getLong("lastUpdate") == value.getLong("lastUpdate") }
            }
            fun authorized(): Boolean = synchronized(lock) {
                !closed && journal().optJSONObject(id)?.let { valid(it) } == true
            }
            if (current() == null) continue
            try {
                val path = "/api/me/progress/" + snapshot.getString("key")
                val name = snapshot.getString("name")
                val remote = try { JSONObject(request("GET", path, null, name) { authorized() }) } catch (e: HttpErr) { if (e.code == 404) null else throw e }
                val latest = synchronized(lock) {
                    val j = journal()
                    val e = current() ?: return@synchronized null
                    // Pin the first observed server timestamp before another attempt can replace
                    // sent. A failure before that PATCH writes must not lose the old acknowledgement.
                    if (remote != null && matches(remote, e.optJSONObject("sent"))) {
                        e.put("ack", remote)
                        e.remove("sent")
                        j.put(id, e)
                        store(j)
                    }
                    e
                } ?: continue
                // ABS has no conditional PATCH: external writes between GET and PATCH cannot be made atomic here.
                val conflict = remote != null && remote.optLong("lastUpdate") > value.getLong("lastUpdate") &&
                    !acknowledged(remote, latest)
                var ack: JSONObject? = null
                if (!conflict) {
                    // Persist attempt before PATCH: a lost response or first-record server timestamp
                    // can then be recognized on the next read, including after process death.
                    synchronized(lock) {
                        val j = journal(); val e = j.optJSONObject(id)
                        if (current() != null && e != null) { e.put("sent", value); store(j) }
                    }
                    if (current() == null) continue
                    val body = JSONObject(value.toString())
                    if (!body.optBoolean("isFinished")) body.remove("isFinished")
                    request("PATCH", path, body, name) { authorized() }
                    // PATCH returns no progress row. Read back its server-created timestamp before
                    // clearing the attempt, including if a newer local event arrived in flight.
                    val confirmed = JSONObject(request("GET", path, null, name) { authorized() })
                    if (matches(confirmed, value)) ack = confirmed
                }
                synchronized(lock) {
                    val j = journal(); val e = j.optJSONObject(id)
                    if (e != null && !closed && valid(e)) {
                        if (e.getJSONObject("value").getLong("lastUpdate") == value.getLong("lastUpdate")) {
                            if (conflict) e.put("value", remote)
                            e.put("dirty", false).put("tries", 0).put("next", 0)
                        }
                        e.remove("sent")
                        e.remove("ack")
                        ack?.let { e.put("ack", it) }
                        // A newer local event remains dirty; ack matches only this server timestamp.
                        store(j)
                    }
                }
            } catch (error: Exception) {
                android.util.Log.w("ProgressSync", "Replay deferred: " + error.javaClass.simpleName)
                synchronized(lock) {
                    val j = journal(); val e = j.optJSONObject(id)
                    if (e != null && !closed && valid(e)) {
                        val tries = (e.optInt("tries") + 1).coerceAtMost(10)
                        e.put("tries", tries).put("next", clock() + minOf(300_000L, 1_000L shl (tries - 1)))
                        store(j)
                    }
                }
            }
        }
    }
}
