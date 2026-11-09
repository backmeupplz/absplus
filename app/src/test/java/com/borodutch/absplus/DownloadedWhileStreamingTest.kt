package com.borodutch.absplus

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Looper
import androidx.media3.common.Player
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import com.google.android.material.button.MaterialButton
import com.sun.net.httpserver.HttpServer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.IOException
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** #583: a book downloaded while it streams keeps playing from the phone once the network is gone.
 * Real service ExoPlayer, a real queue built by Main.start() while nothing is downloaded, and a loopback server
 * that serves the stream until it is stopped (airplane mode). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DownloadedWhileStreamingTest {
    // Two 120 s files: longer than ExoPlayer's 50 s buffer, so seeks past it must open the source again.
    private val seconds = 120
    private fun wav(tone: Int): ByteArray {
        val size = seconds * 8000 * 2
        val b = ByteBuffer.allocate(44 + size).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36 + size).put("WAVEfmt ".toByteArray()).putInt(16)
            .putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16)
            .put("data".toByteArray()).putInt(size)
        while (b.hasRemaining()) b.putShort(tone.toShort())
        return b.array()
    }
    private val audio = listOf(wav(1), wav(2))
    private val book = Now("streamed", null, "Streamed book", "Fixture", listOf(
        Track("one", ".wav", audio[0].size.toLong(), seconds.toDouble(), 0.0),
        Track("two", ".wav", audio[1].size.toLong(), seconds.toDouble(), seconds.toDouble())))

    private class Host(val audio: Map<String, ByteArray>) : AutoCloseable {
        val server: HttpServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        private val pool = Executors.newCachedThreadPool()
        val url get() = "http://127.0.0.1:" + server.address.port
        val media = java.util.concurrent.CopyOnWriteArrayList<String>()
        init {
            server.executor = pool
            server.createContext("/") { x ->
                x.requestBody.close()
                val path = x.requestURI.path
                val file = audio[path.substringAfterLast("/")]
                if (path.startsWith("/api/items/streamed/file/") && file != null) {
                    media += path
                    val from = x.requestHeaders.getFirst("Range")?.removePrefix("bytes=")?.substringBefore("-")?.toInt() ?: 0
                    x.responseHeaders.add("Content-Range", "bytes $from-${file.size - 1}/${file.size}")
                    x.sendResponseHeaders(if (from > 0) 206 else 200, (file.size - from).toLong())
                    runCatching { x.responseBody.use { it.write(file, from, file.size - from) } }
                    return@createContext
                }
                // A token that stays valid for the whole test, so streaming never needs /auth/refresh.
                val body = (if (path == "/login") """{"user":{"id":"stream-user","username":"fixture","accessToken":"x.eyJleHAiOjk5OTk5OTk5OTl9.x"}}""" else "{}").toByteArray()
                x.sendResponseHeaders(200, body.size.toLong())
                x.responseBody.use { it.write(body) }
            }
            server.start()
        }
        /** airplane mode: every later connection is refused */
        override fun close() { server.stop(0); pool.shutdownNow() }
    }

    private fun drainUntil(seconds: Long = 5, message: () -> String = { "condition not reached" }, check: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
        while (!check() && System.nanoTime() < deadline) { shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(10)); Thread.sleep(10) }
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(message(), check())
    }
    private fun Main.call(name: String, vararg args: Any) = Main::class.java.declaredMethods.single { it.name == name }
        .apply { isAccessible = true }.invoke(this, *args)
    /** what Dl.fetch leaves behind: the whole file under its final name */
    private fun download(i: Int) = Abs.file(book.item, book.tracks[i]).apply { parentFile!!.mkdirs(); writeBytes(audio[i]) }

    private fun withPlayer(test: (Host, Main, ExoPlayer) -> Unit) {
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        Host(mapOf("one" to audio[0], "two" to audio[1])).use { host ->
            Abs.login(host.url, "fixture", "fixture", true)
            book.tracks.forEach { Abs.file(book.item, it).delete() }
            val service = Robolectric.buildService(PlayerService::class.java).create()
            val component = ComponentName(RuntimeEnvironment.getApplication(), PlayerService::class.java)
            val binder = service.get().onBind(Intent("androidx.media3.session.MediaSessionService").setComponent(component))
            shadowOf(RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(component, binder)
            val session = PlayerService::class.java.getDeclaredField("session").apply { isAccessible = true }.get(service.get()) as MediaSession
            val player = (session.player as BookPlayer).wrappedPlayer as ExoPlayer
            val activity = Robolectric.buildActivity(Main::class.java).create().start().resume().visible()
            try {
                drainUntil { Main::class.java.getDeclaredField("ctl").apply { isAccessible = true }.get(activity.get()) != null }
                test(host, activity.get(), player)
            } finally {
                Abs.clearPlayback() // no progress push during teardown
                activity.pause().stop().destroy(); service.destroy()
                book.tracks.forEach { Abs.file(book.item, it).delete() }
                Abs.logout()
            }
        }
    }

    private fun settled(p: ExoPlayer, index: Int, ms: Long) = drainUntil(15, { "state ${p.playbackState}, error ${p.playerError}, at ${p.currentMediaItemIndex}/${p.currentPosition}" }) {
        p.playerError != null || (p.playbackState == Player.STATE_READY && p.currentMediaItemIndex == index && p.currentPosition == ms)
    }

    @Test fun downloadFinishedMidStreamPlaysFromThePhoneAfterTheNetworkGoes() = withPlayer { host, main, player ->
        main.call("start", book, 10.0, false, Abs.scope(playback = true))
        drainUntil { player.mediaItemCount == 2 }
        assertEquals("http", player.currentMediaItem!!.localConfiguration!!.uri.scheme) // the queue streams
        player.setPlaybackSpeed(1.5f)
        settled(player, 0, 10_000)
        assertNull(player.playerError)
        drainUntil(15) { !player.isLoading }
        assertTrue("the buffer ends inside the first file", player.bufferedPosition < (seconds - 10) * 1000L)
        assertEquals(listOf("/api/items/streamed/file/one"), host.media.distinct())
        val queue = (0 until player.mediaItemCount).map { player.getMediaItemAt(it) }

        download(0); download(1)
        host.close() // airplane mode
        // Past the buffer in the current file, then across the file boundary: both open the source again.
        player.seekTo(0, 100_000)
        settled(player, 0, 100_000)
        assertNull(player.playerError)
        player.seekTo(1, 30_000)
        settled(player, 1, 30_000)
        assertNull(player.playerError)
        // Nothing was rebuilt: same items, same speed, and the stream only ever reached the first file.
        assertEquals(queue, (0 until player.mediaItemCount).map { player.getMediaItemAt(it) })
        assertEquals(1.5f, player.playbackParameters.speed)
        assertEquals(listOf("/api/items/streamed/file/one"), host.media.distinct())
    }

    @Test fun retryAfterAnOfflineFailurePlaysTheDownloadedFile() = withPlayer { host, main, player ->
        host.close() // offline before anything is downloaded: the stream fails
        main.call("start", book, 130.0, false, Abs.scope(playback = true))
        drainUntil { player.mediaItemCount == 2 }
        val ctl = Main::class.java.getDeclaredField("ctl").apply { isAccessible = true }.get(main) as Player
        drainUntil(30, { "state ${player.playbackState}" }) { ctl.playerError != null }
        main.call("updatePlayer")
        val mini = Main::class.java.getDeclaredField("miniPlay").apply { isAccessible = true }.get(main) as MaterialButton
        assertEquals(main.getString(R.string.action_retry_playback), mini.contentDescription)

        assertEquals(1, player.currentMediaItemIndex); assertEquals(10_000L, player.currentPosition)
        val queue = (0 until player.mediaItemCount).map { player.getMediaItemAt(it) }

        download(1)
        mini.performClick() // the mini player's Retry: prepare() the same queue, then play
        drainUntil { player.playerError == null && player.playWhenReady } // the click reaches the session player
        // Robolectric's audio sink runs faster than real time; plain playback past the old stall point is the proof.
        drainUntil(20, { "state ${player.playbackState}, error ${player.playerError}, at ${player.currentMediaItemIndex}/${player.currentPosition}" }) {
            player.playerError != null || player.currentMediaItemIndex == 1 && player.currentPosition > 60_000 }
        assertNull(player.playerError)
        assertTrue(player.playWhenReady)
        assertEquals(queue, (0 until player.mediaItemCount).map { player.getMediaItemAt(it) }) // still the streaming queue
    }

    @Test fun onlyAWholeDownloadOfTheBoundTitleReplacesItsStream() = withPlayer { host, main, _ ->
        main.call("start", book, 0.0, false, Abs.scope(playback = true))
        val scope = Abs.scope(playback = true)
        fun open(url: String, at: Long = 0): Pair<Uri?, ByteArray> {
            val source = SessionDataSource()
            try {
                source.open(DataSpec.Builder().setUri(url).setKey(scope.generation.toString()).setPosition(at).build())
                val bytes = ByteArray(4)
                var got = 0
                while (got < bytes.size) got += source.read(bytes, got, bytes.size - got).also { check(it > 0) }
                return source.uri to bytes
            } finally { source.close() }
        }
        val one = "${host.url}/api/items/streamed/file/one"
        host.close()
        // A partly written file (shorter than the track) is not a download yet: the stream is tried and fails.
        Abs.file(book.item, book.tracks[0]).apply { parentFile!!.mkdirs(); writeBytes(audio[0].copyOf(1000)) }
        assertTrue(runCatching { open(one) }.exceptionOrNull() is IOException)
        val f = download(0)
        val (uri, bytes) = open(one, 5000)
        assertEquals(Uri.fromFile(f), uri)
        assertArrayEquals(audio[0].copyOfRange(5000, 5004), bytes)
        // Another title's URL, or another server's, is never answered from this title's files.
        assertTrue(runCatching { open("${host.url}/api/items/other/file/one") }.exceptionOrNull() is IOException)
        assertTrue(runCatching { open("http://127.0.0.2:9/api/items/streamed/file/one") }.exceptionOrNull() != null)
    }
}
