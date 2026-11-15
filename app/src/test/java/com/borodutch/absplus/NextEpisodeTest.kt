package com.borodutch.absplus

import android.content.ComponentName
import android.content.Intent
import android.os.Looper
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import com.sun.net.httpserver.HttpServer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.TimeUnit

/** A finished podcast episode rolls on to the next one in the service, offline from the downloads. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NextEpisodeTest {
    private val seconds = 2
    private val wav = ByteBuffer.allocate(44 + seconds * 16000).order(ByteOrder.LITTLE_ENDIAN).apply {
        val size = seconds * 16000
        put("RIFF".toByteArray()).putInt(36 + size).put("WAVEfmt ".toByteArray()).putInt(16)
            .putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16).put("data".toByteArray()).putInt(size)
        while (hasRemaining()) putShort(1)
    }.array()
    private fun track(id: String) = Track(id, ".wav", wav.size.toLong(), seconds.toDouble(), 0.0)
    private fun episode(id: String, at: Long) = JSONObject().put("id", id).put("title", "Episode $id").put("publishedAt", at)
        .put("audioFile", JSONObject().put("ino", id).put("duration", seconds).put("metadata", JSONObject().put("ext", ".wav").put("size", wav.size)))

    private fun drainUntil(check: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
        while (!check() && System.nanoTime() < deadline) { shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(10)); Thread.sleep(10) }
        assertTrue(check())
    }

    @Test fun endedEpisodePlaysTheNextDownloadedOneOffline() {
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { x ->
            x.requestBody.close()
            val body = (if (x.requestURI.path == "/login") """{"user":{"id":"pod-user","username":"fixture","accessToken":"x.eyJleHAiOjk5OTk5OTk5OTl9.x"}}""" else "{}").toByteArray()
            x.sendResponseHeaders(200, body.size.toLong()); x.responseBody.use { it.write(body) }
        }
        server.start()
        Abs.login("http://127.0.0.1:" + server.address.port, "fixture", "fixture", true)
        server.stop(0) // airplane mode from here on
        Abs.offline = true
        // Oldest first: a, b, c, d. b is newer than a but not downloaded; c is downloaded; d is newest.
        val item = JSONObject().put("id", "pod").put("mediaType", "podcast").put("media", JSONObject()
            .put("metadata", JSONObject().put("title", "Pod").put("author", "Host"))
            .put("episodes", JSONArray().put(episode("d", 4)).put(episode("b", 2)).put(episode("a", 1)).put(episode("c", 3))))
        (Abs::class.java.getDeclaredMethod("cacheFile", String::class.java).apply { isAccessible = true }
            .invoke(Abs, "/api/items/pod?expanded=1") as File).apply { parentFile!!.mkdirs(); writeText(item.toString()) }
        listOf("a", "c", "d").forEach { Abs.file("pod", track(it)).apply { parentFile!!.mkdirs(); writeBytes(wav) } }

        val service = Robolectric.buildService(PlayerService::class.java).create()
        val component = ComponentName(RuntimeEnvironment.getApplication(), PlayerService::class.java)
        val binder = service.get().onBind(Intent("androidx.media3.session.MediaSessionService").setComponent(component))
        shadowOf(RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(component, binder)
        val session = PlayerService::class.java.getDeclaredField("session").apply { isAccessible = true }.get(service.get()) as MediaSession
        val player = (session.player as BookPlayer).wrappedPlayer as ExoPlayer
        try {
            val scope = Abs.scope(playback = true)
            val a = Now("pod", "a", "Episode a", "Pod", listOf(track("a")))
            Abs.bindPlayback(a, scope)
            player.setMediaItems(Abs.mediaItems(a, scope), 0, 1_000)
            player.prepare(); player.play()
            drainUntil { Abs.now?.ep == "c" && player.isPlaying }
            assertEquals(Abs.mediaId(Abs.now!!, scope, 0), player.currentMediaItem!!.mediaId)
            assertEquals("file", player.currentMediaItem!!.localConfiguration!!.uri.scheme)
            assertEquals(1.0, Abs.pct("pod/a")!!, 0.0)
            assertEquals("c", Abs.loadNow()!!.ep) // a restart picks up where it rolled on to
        } finally {
            Abs.clearPlayback()
            service.destroy()
            Abs.logout()
        }
    }
}
