package com.borodutch.absplus

import android.graphics.Bitmap
import android.util.LruCache
import android.widget.ImageView
import com.sun.net.httpserver.HttpServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CoverIsolationTest {
    // Observe completion of the real Covers.load worker, without replacing its disk/network path.
    private class Image : ImageView(RuntimeEnvironment.getApplication()) {
        val completed = CountDownLatch(1)
        override fun setContentDescription(description: CharSequence?) {
            super.setContentDescription(description)
            if (description == "Cover" || description == "Cover unavailable" || description == "No cover available") completed.countDown()
        }
        fun finish() {
            val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (completed.count > 0 && System.nanoTime() < until) {
                org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle(); Thread.sleep(10)
            }
            assertEquals("cover worker did not finish", 0L, completed.count)
        }
    }
    private class Host : AutoCloseable {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        private val pool = Executors.newCachedThreadPool()
        val url get() = "http://127.0.0.1:" + server.address.port
        @Volatile var account: String? = "first-id"
        @Volatile var code = 200
        @Volatile var hold = false
        var entered = CountDownLatch(1)
        var release = CountDownLatch(1)
        val reads = AtomicInteger()
        private val png = ByteArrayOutputStream().also {
            Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, it)
        }.toByteArray()
        init {
            server.executor = pool
            server.createContext("/") { x ->
                val login = x.requestURI.path == "/login"
                x.requestBody.close()
                val status = if (login) 200 else code
                val body = if (login) JSONObject().put("user", JSONObject().put("username", "same")
                    .put("id", account).put("accessToken", "fixture")).toString().toByteArray() else png
                if (!login) {
                    reads.incrementAndGet()
                    if (hold) { entered.countDown(); release.await(5, TimeUnit.SECONDS) }
                }
                x.sendResponseHeaders(status, body.size.toLong())
                x.responseBody.use { it.write(body) }
            }
            server.start()
        }
        fun login() { Abs.login(url, "same", "fixture", true) }
        override fun close() { release.countDown(); server.stop(0); pool.shutdownNow() }
    }
    private fun setup() { Abs.init(RuntimeEnvironment.getApplication()); Abs.logout() }
    // Do not leave a logged-in singleton pointing at a fixture server that has stopped.
    @After fun tearDown() { Abs.logout() }
    private fun load(id: String): Image = Image().also { Covers.load(it, id) }
    @Suppress("UNCHECKED_CAST")
    private fun clearMemory() {
        (Covers::class.java.getDeclaredField("mem").apply { isAccessible = true }.get(Covers) as LruCache<String, Bitmap>).evictAll()
    }

    @Test fun sameUsernameDifferentIdAndMissingIdCannotReuseMemoryDiskOrMissingCovers() {
        setup()
        for (missing in listOf(false, true)) Host().use { h ->
            if (missing) h.account = null
            h.login()
            load("book").finish()
            assertEquals(1, h.reads.get())
            assertNotNull(load("book").drawable) // real memory hit
            clearMemory()
            load("book").finish()
            assertEquals(1, h.reads.get()) // real disk hit
            h.code = 404; load("absent").finish()
            assertEquals(2, h.reads.get())
            if (!missing) h.account = "replacement-id"
            h.login(); h.code = 200
            load("book").finish() // must bypass both old memory and old disk
            load("absent").finish() // must not reuse the old negative cache
            assertEquals(4, h.reads.get())
            assertNotNull(load("book").drawable)
        }
    }

    @Test fun staleInflightSuccessAndMissingCannotPopulateReusableAccountCaches() {
        setup()
        // Relogin as the SAME immutable owner: a new generation must still reject late writes.
        for (status in listOf(200, 404)) Host().use { h ->
            h.login(); h.code = status; h.hold = true
            val stale = load("late")
            assertTrue(h.entered.await(5, TimeUnit.SECONDS))
            h.login()
            val placeholder = stale.drawable
            h.release.countDown()
            val pool = Covers::class.java.getDeclaredField("pool").apply { isAccessible = true }.get(Covers) as java.util.concurrent.ExecutorService
            // Drain every queued worker before checking stale publication.
            val drained = CountDownLatch(4)
            repeat(4) { pool.execute { drained.countDown(); drained.await(5, TimeUnit.SECONDS) } }
            assertTrue(drained.await(5, TimeUnit.SECONDS))
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            assertSame(placeholder, stale.drawable)
            assertEquals("Loading cover", stale.contentDescription)
            h.hold = false; h.code = 200
            load("late").finish()
            assertEquals("late success/404 must not seed disk, memory or missing caches", 2, h.reads.get())
            assertNotNull(load("late").drawable)
        }
    }
}
