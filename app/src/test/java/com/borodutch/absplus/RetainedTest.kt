package com.borodutch.absplus

import android.content.Context
import org.robolectric.RuntimeEnvironment
import com.sun.net.httpserver.HttpServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class RetainedTest {
    @Test fun retainedBooksAndEpisodesRequireSuccessfulSameServerLogin() {
        Abs.init(RuntimeEnvironment.getApplication())
        Abs.logout()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        var fail = false
        val s = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val audio = """{"ino":"1","duration":60,"metadata":{"ext":".mp3","size":7},"token":"secret"}"""
        s.createContext("/") { x ->
            val path = x.requestURI.path
            if (path.endsWith("/late")) { entered.countDown(); release.await(5, TimeUnit.SECONDS) }
            val body = when {
                path.endsWith("/login") -> """{"user":{"username":"fixture","accessToken":"fixture"}}"""
                path.endsWith("/pod") -> """{"id":"pod","mediaType":"podcast","media":{"metadata":{"title":"Podcast","author":"Author"},"episodes":[{"id":"ep","title":"Episode","audioFile":$audio}]},"token":"secret"}"""
                else -> """{"id":"book","mediaType":"book","media":{"metadata":{"title":"Book","authorName":"Author"},"tracks":[$audio]},"token":"secret"}"""
            }.toByteArray()
            x.sendResponseHeaders(if (fail) 401 else 200, body.size.toLong())
            x.responseBody.use { it.write(body) }
        }
        s.start()
        val url = "http://127.0.0.1:${s.address.port}"
        val t = Track("1", ".mp3", 7, 60.0, 0.0)
        try {
            // Unknown legacy files must not be silently attributed to the next login.
            File(Abs.dir, "legacy/1.mp3").apply { parentFile!!.mkdirs(); writeText("fixture") }
            Abs.login(url, "fixture", "fixture", true)
            assertFalse(Abs.done("legacy", t))
            for (id in listOf("book", "pod")) {
                Abs.get("/api/items/$id?expanded=1")
                Abs.file(id, t).apply { parentFile!!.mkdirs(); writeText("fixture") }
            }
            Abs.dlChanged()
            assertTrue(Abs.downloaded("book")); assertTrue(Abs.downloaded("pod"))
            val old = Dl.Job(Now("book", null, "Book", "Author", listOf(t)))
            val bytes = Abs.file("book", t)
            Abs.logout()
            assertTrue(bytes.exists()); assertNull(Abs.me); assertTrue(Abs.accounts().isEmpty())
            assertTrue(Abs.downloads().isEmpty()); assertNull(Abs.cached("/api/items/book?expanded=1"))
            fail = true
            assertTrue(runCatching { Abs.login(url, "fixture", "bad", true) }.isFailure)
            assertTrue(Abs.downloads().isEmpty())
            fail = false
            // Different base path is a different server even with identical IDs.
            Abs.login("$url/other", "fixture", "fixture", true)
            assertFalse(Abs.done("book", t)); assertTrue(Abs.downloads().isEmpty())
            Abs.logout()
            Abs.login("$url/", "fixture", "fixture", true)
            assertNotEquals(old.epoch, Abs.mediaEpoch)
            assertEquals(bytes, old.file(t))
            val current = Dl.Job(old.n)
            Dl.jobs.add(current)
            Dl::class.java.getDeclaredMethod("finish", Dl.Job::class.java, String::class.java).apply { isAccessible = true }.invoke(Dl, old, null)
            assertTrue(Dl.jobs.contains(current))
            Dl.clear()
            Abs.offline = true
            assertEquals(setOf("book", "pod"), Abs.downloads().map { it.name }.toSet())
            assertEquals("Book", Abs.cachedCard("book").title)
            assertEquals("Podcast", Abs.cachedCard("pod").title)
            assertTrue(Abs.downloaded("book")); assertTrue(Abs.downloaded("pod"))
            assertEquals("file", Abs.uri("book", t).scheme)
            val book = Abs.cached("/api/items/book?expanded=1")!!
            assertFalse(book.contains("secret")); assertFalse(book.contains("token"))
            val ep = JSONObject(Abs.cached("/api/items/pod?expanded=1")!!).getJSONObject("media").getJSONArray("episodes").getJSONObject(0)
            assertEquals("Episode", ep.getString("title"))
            assertTrue(Abs.done("pod", Abs.track(ep.getJSONObject("audioFile"), 0.0)))
            val worker = thread { runCatching { Abs.get("/api/items/late?expanded=1") } }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            Abs.logout(); release.countDown(); worker.join(5000)
            assertFalse(worker.isAlive)
            Abs.login(url, "fixture", "fixture", true)
            assertNull(Abs.cached("/api/items/late?expanded=1"))
        } finally { release.countDown(); s.stop(0); Abs.logout() }
    }
}
