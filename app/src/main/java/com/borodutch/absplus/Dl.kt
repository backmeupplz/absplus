package com.borodutch.absplus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread
import kotlin.math.min

/**
 * Downloads titles one file at a time into Abs.dir. Each file is written to "<name>.part" and continued with a Range
 * request (and a fresh token), so closing the app, a reboot or a dropped connection never starts a file over.
 * The queue is kept in prefs ("dlq") and picked up on the next app start; DlService keeps it running in the background.
 */
object Dl {
    class Job(val n: Now) {
        val epoch = Abs.mediaEpoch
        val server = Abs.server
        val dir = Abs.mediaDir
        fun file(t: Track) = Abs.mediaFile(dir, n.item, t)
        fun done(t: Track) = file(t).isFile && file(t).length() == t.size
        val total = n.tracks.sumOf { it.size }
        @Volatile var got = 0L
        @Volatile var waiting = false // couldn't reach the server, will retry
    }

    val jobs = CopyOnWriteArrayList<Job>()
    /** a title finished, failed (with a message) or the queue ran dry; called on the downloader thread */
    @Volatile var onChange: ((String?) -> Unit)? = null
    @Volatile private var worker: Thread? = null
    private class Stop : Exception() // the title was cancelled mid-file

    fun job(key: String) = jobs.firstOrNull { it.n.key == key }
    fun pct(j: Job) = if (j.total > 0) min(1.0, j.got.toDouble() / j.total) else 0.0
    val idle get() = worker == null

    fun load() {
        if (jobs.isNotEmpty()) return
        val a = JSONArray(Abs.p.getString("dlq", "[]"))
        for (i in 0 until a.length()) jobs += Job(Now.of(a.getJSONObject(i))).also { measure(it) }
    }

    private fun save() = Abs.p.edit().putString("dlq", JSONArray().apply { jobs.forEach { put(it.n.json()) } }.toString()).apply()

    fun add(c: Context, n: Now) {
        synchronized(this) { if (job(n.key) == null) { jobs += Job(n).also { measure(it) }; save() } }
        start(c)
    }

    /** (re)starts the background service when there is something to download */
    fun start(c: Context) {
        if (jobs.isNotEmpty()) runCatching { ContextCompat.startForegroundService(c, Intent(c, DlService::class.java)) }
    }

    /** forgets a title's download and deletes whatever of it is on disk */
    fun cancel(n: Now) = synchronized(this) {
        jobs.removeAll { it.n.key == n.key }
        save()
        Abs.remove(n.tracks.map { Abs.file(n.item, it) })
    }

    /** on logout: stop downloading, keep the files */
    fun clear() = synchronized(this) { jobs.clear() }

    private fun part(f: File) = File(f.path + ".part")

    /** bytes of the title on disk, counting files other than [skip] */
    private fun measure(j: Job, skip: Track? = null) = j.n.tracks.filter { it !== skip }.sumOf { t ->
        if (j.done(t)) t.size else part(j.file(t)).length()
    }.also { if (skip == null) j.got = it }

    /** the queue runner; DlService starts it, one at a time */
    fun run(s: DlService) = synchronized(this) {
        if (worker?.isAlive == true) return
        worker = thread(name = "downloads") {
            val wake = s.getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "absplus:downloads")
            wake.setReferenceCounted(false)
            var wait = 2_000L
            while (true) {
                val j = synchronized(this) { jobs.firstOrNull().also { if (it == null) worker = null } } ?: break
                try {
                    for (t in j.n.tracks) if (!j.done(t)) {
                        wake.acquire(30 * 60_000L)
                        fetch(j, t, s)
                    }
                    finish(j, null)
                    wait = 2_000
                } catch (_: Stop) {
                } catch (e: Expired) { // signed out: the queue waits for the next start
                    synchronized(this) { worker = null }
                    break
                } catch (e: HttpErr) {
                    if (e.code in 400..499 && e.code !in setOf(401, 408, 429)) finish(j, "Couldn't download “${j.n.title}” (${e.message})")
                    else wait = pause(j, wait)
                } catch (e: IOException) {
                    wait = pause(j, wait)
                }
            }
            wake.release()
            onChange?.invoke(null)
            s.stop()
        }
    }

    private fun finish(j: Job, msg: String?) {
        synchronized(this) {
            if (j.epoch != Abs.mediaEpoch || !jobs.remove(j)) return
            save()
        }
        Abs.dlChanged()
        onChange?.invoke(msg)
    }

    /** waits before retrying a title that couldn't reach the server (returns early if it's cancelled) */
    private fun pause(j: Job, wait: Long): Long {
        j.waiting = true
        val until = System.currentTimeMillis() + wait
        while (System.currentTimeMillis() < until && jobs.contains(j)) Thread.sleep(250)
        return min(wait * 2, 60_000)
    }

    private fun fetch(j: Job, t: Track, s: DlService) {
        if (j.epoch != Abs.mediaEpoch || !jobs.contains(j)) throw Stop()
        val f = j.file(t)
        val p = part(f)
        f.parentFile!!.mkdirs()
        if (t.size > 0 && p.length() > t.size) p.delete() // not ours
        val base = measure(j, t)
        val auth = Abs.token(epoch = j.epoch)
        if (j.epoch != Abs.mediaEpoch || !jobs.contains(j)) throw Stop()
        // a range starting at the end makes the server answer 500, so a complete part goes straight to the rename
        if (t.size <= 0 || p.length() < t.size) resume(URL("${j.server}/api/items/${j.n.item}/file/${t.ino}/download"), auth, p) { have ->
            if (j.epoch != Abs.mediaEpoch || !jobs.contains(j)) throw Stop()
            j.waiting = false
            j.got = base + have
            s.progress(j)
        }
        synchronized(this) {
            if (j.epoch != Abs.mediaEpoch || !jobs.contains(j)) throw Stop()
            if (t.size > 0 && p.length() != t.size) throw IOException("${f.name}: ${p.length()} of ${t.size} bytes")
            if (!p.renameTo(f)) throw IOException("Can't save ${f.name}")
        }
    }

    /** Continues [part] with the rest of [url] (Range from its size), starting over if the server ignores the range. */
    fun resume(url: URL, token: String, part: File, onBytes: (Long) -> Unit) {
        val c = url.openConnection() as HttpURLConnection
        try {
            c.instanceFollowRedirects = false
            c.connectTimeout = 15_000
            c.readTimeout = 30_000
            c.setRequestProperty("Authorization", "Bearer $token")
            val have = part.length()
            if (have > 0) c.setRequestProperty("Range", "bytes=$have-")
            val code = c.responseCode
            if (code >= 300) throw HttpErr(code)
            val append = have > 0 && code == 206
            var n = if (append) have else 0L
            onBytes(n)
            c.inputStream.use { i ->
                FileOutputStream(part, append).use { o ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val r = i.read(buf)
                        if (r < 0) break
                        o.write(buf, 0, r)
                        n += r
                        onBytes(n)
                    }
                }
            }
        } finally {
            c.disconnect()
        }
    }
}

/** Keeps downloads going while the app is in the background, with a progress notification. */
class DlService : Service() {
    private var last = 0L

    override fun onBind(i: Intent?) = null

    override fun onStartCommand(i: Intent?, flags: Int, id: Int): Int {
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel("dl", "Downloads", NotificationManager.IMPORTANCE_LOW))
        // refused once Android 15's daily data sync allowance is used up: then it only downloads while the app is open
        runCatching { ServiceCompat.startForeground(this, 1, note(Dl.jobs.firstOrNull()), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) }
        Dl.run(this)
        return START_NOT_STICKY
    }

    private fun note(j: Dl.Job?): Notification {
        val more = Dl.jobs.size - 1
        return NotificationCompat.Builder(this, "dl")
            .setSmallIcon(R.drawable.i_download)
            .setContentTitle(j?.n?.title ?: "Downloads")
            .setContentText(j?.let { "${(Dl.pct(it) * 100).toInt()}%" + if (more > 0) " · $more more" else "" })
            .setProgress(1000, j?.let { (Dl.pct(it) * 1000).toInt() } ?: 0, j == null || j.total == 0L)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, Main::class.java), PendingIntent.FLAG_IMMUTABLE))
            .build()
    }

    /** from the downloader thread, as bytes arrive */
    fun progress(j: Dl.Job) {
        val now = System.currentTimeMillis()
        if (now - last < 1000) return
        last = now
        getSystemService(NotificationManager::class.java).notify(1, note(j))
    }

    fun stop() {
        if (!Dl.idle) return // a new download started in the meantime
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // Android 15+ caps how long a data sync can run; whatever is left resumes on the next app start
    override fun onTimeout(startId: Int, fgsType: Int) {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
}
