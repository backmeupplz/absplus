package com.borodutch.absplus

import com.sun.net.httpserver.HttpServer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.net.InetSocketAddress
import java.net.URL

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DownloadQueueTest {
    @Test fun transientFileFailurePreservesSiblingAndQueueAcrossReload() {
        val c = RuntimeEnvironment.getApplication()
        Abs.init(c)
        Abs.p.edit().clear().commit()
        Dl.clear()
        val n = Now("retry-fixture", null, "Fixture", "", listOf(
            Track("one", ".mp3", 7, 60.0, 0.0), Track("two", ".mp3", 7, 60.0, 60.0)))
        val first = Abs.file(n.item, n.tracks[0]).apply { parentFile!!.mkdirs(); writeText("fixture") }
        val second = Abs.file(n.item, n.tracks[1])
        val part = File(second.path + ".part").apply { writeText("fix") }
        Dl.add(c, n)
        var attempts = 0
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/file") { x ->
            if (++attempts == 1) {
                x.sendResponseHeaders(503, -1)
            } else {
                assertEquals("bytes=3-", x.requestHeaders.getFirst("Range"))
                x.sendResponseHeaders(206, 4)
                x.responseBody.use { it.write("ture".toByteArray()) }
            }
            x.close()
        }
        server.start()
        val url = URL("http://127.0.0.1:${server.address.port}/file")
        try {
            try { Dl.resume(url, "fixture", part) {}; fail("Expected HTTP failure") } catch (e: HttpErr) { assertEquals(503, e.code) }
            assertEquals("fixture", first.readText())
            assertEquals("fix", part.readText())
            Dl.jobs.clear() // process-local state is gone; reload durable prefs
            Dl.load()
            assertNotNull(Dl.job(n.key))
            assertEquals(10L, Dl.job(n.key)!!.got)
            Dl.resume(url, "fixture", part) {}
            assertEquals("fixture", part.readText())
            assertEquals("fixture", first.readText())
            Dl.cancel(n)
            Dl.jobs.clear(); Dl.load()
            assertNull(Dl.job(n.key))
            assertFalse(first.exists())
        } finally { server.stop(0); Dl.clear(); first.parentFile!!.deleteRecursively() }
    }
}
