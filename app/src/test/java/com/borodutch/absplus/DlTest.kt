package com.borodutch.absplus

import com.sun.net.httpserver.HttpServer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.net.InetSocketAddress
import java.net.URL
import kotlin.random.Random

class DlTest {
    private val body = Random(1).nextBytes(300_000)
    private val ranges = mutableListOf<String?>()

    /** serves [body], honoring "Range: bytes=N-" unless [ranged] is false */
    private fun fetch(part: File, ranged: Boolean = true) {
        val s = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        s.createContext("/f") { x ->
            val r = x.requestHeaders.getFirst("Range").also { ranges += it }
            val from = if (ranged && r != null) r.removePrefix("bytes=").removeSuffix("-").toInt() else 0
            if (from > 0) x.responseHeaders.add("Content-Range", "bytes $from-${body.size - 1}/${body.size}")
            x.sendResponseHeaders(if (from > 0) 206 else 200, (body.size - from).toLong())
            x.responseBody.use { it.write(body, from, body.size - from) }
        }
        s.start()
        try { Dl.resume(URL("http://127.0.0.1:${s.address.port}/f"), "t", part) {} } finally { s.stop(0) }
    }

    @Test fun continuesAPartialFileWithARange() {
        val part = File.createTempFile("absdl", ".part").apply { writeBytes(body.copyOf(123_456)) }
        fetch(part)
        assertEquals("bytes=123456-", ranges.single())
        assertArrayEquals(body, part.readBytes())
    }

    @Test fun startsOverWhenTheServerIgnoresTheRange() {
        val part = File.createTempFile("absdl", ".part").apply { writeBytes(ByteArray(5_000) { 7 }) }
        fetch(part, ranged = false)
        assertArrayEquals(body, part.readBytes())
    }

    @Test fun freshFileAsksForEverything() {
        val part = File.createTempFile("absdl", ".part").apply { delete() }
        fetch(part)
        assertEquals(null, ranges.single())
        assertArrayEquals(body, part.readBytes())
    }
}
