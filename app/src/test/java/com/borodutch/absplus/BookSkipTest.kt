package com.borodutch.absplus

import android.os.Looper
import android.view.View
import android.view.ViewGroup
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog
import java.util.concurrent.TimeUnit
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Real service ExoPlayer + MediaSession + MediaController, including the actual full-player buttons.
 * Synthetic local PCM files supply real seekable timelines. No network, account or fake Player.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class BookSkipTest {
    private lateinit var controller: MediaController
    private val book = Now("skip-fixture", null, "Two files", "Fixture", listOf(
        Track("one", ".wav", 0, 100.0, 0.0), Track("two", ".wav", 0, 50.0, 100.0)))

    private fun drainUntil(message: () -> String = { "Media3 command did not settle" }, check: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!check() && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
        assertTrue(message(), check())
    }

    private fun views(v: View): List<View> = listOf(v) + if (v is ViewGroup)
        (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()

    private fun withSession(test: (Main, Player, MediaController) -> Unit) {
        val activity = Robolectric.buildActivity(Main::class.java).create()
        val service = Robolectric.buildService(PlayerService::class.java).create()
        val field = PlayerService::class.java.getDeclaredField("session").apply { isAccessible = true }
        val session = field.get(service.get()) as MediaSession
        val future = MediaController.Builder(activity.get(), session.token).buildAsync()
        try {
            drainUntil { future.isDone }
            controller = future.get()
            Main::class.java.getDeclaredField("ctl").apply { isAccessible = true }.set(activity.get(), controller)
            Abs.now = book
            session.player.setMediaItems(book.tracks.mapIndexed { i, track ->
                val size = (track.duration * 8000 * 2).toInt()
                val wav = ByteBuffer.allocate(44 + size).order(ByteOrder.LITTLE_ENDIAN)
                wav.put("RIFF".toByteArray()).putInt(36 + size).put("WAVEfmt ".toByteArray())
                    .putInt(16).putShort(1).putShort(1).putInt(8000).putInt(16000)
                    .putShort(2).putShort(16).put("data".toByteArray()).putInt(size)
                val file = java.io.File(activity.get().cacheDir, "skip-fixture-$i.wav")
                file.writeBytes(wav.array())
                MediaItem.Builder().setMediaId("${book.key}#$i").setUri(file.toURI().toString()).build()
            }, 0, 0)
            session.player.setPlaybackSpeed(1.5f)
            session.player.prepare()
            drainUntil { controller.mediaItemCount == 2 && controller.isCommandAvailable(Player.COMMAND_SEEK_BACK) }
            test(activity.get(), session.player, controller)
        } finally {
            Abs.now = null // no progress push during fixture teardown
            MediaController.releaseFuture(future)
            shadowOf(Looper.getMainLooper()).idle()
            service.destroy()
            activity.destroy()
        }
    }

    private fun position(p: Player, t: Double) {
        val (i, ms) = book.at(t)
        p.seekTo(i, ms)
        drainUntil { controller.currentMediaItemIndex == i && controller.currentPosition == ms &&
            controller.isCommandAvailable(Player.COMMAND_SEEK_BACK) && controller.isCommandAvailable(Player.COMMAND_SEEK_FORWARD) }
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun expect(p: Player, time: Double, play: Boolean = false) {
        // Even a clamped/no-op command must leave the session queue before the next seed seek.
        shadowOf(Looper.getMainLooper()).idle()
        // ExoPlayer resolves a seek to the exact duration to the final millisecond.
        val tolerance = if (time == book.duration) 0.0011 else 0.0
        drainUntil({ "Expected $time, actual ${Abs.pos(p, book)}, state ${p.playbackState}, error ${p.playerError}, play ${p.playWhenReady}" }) { kotlin.math.abs(Abs.pos(p, book) - time) <= tolerance }
        val (i, ms) = book.at(time)
        assertEquals(i, p.currentMediaItemIndex)
        assertEquals(ms.toDouble(), p.currentPosition.toDouble(), tolerance * 1000)
        assertEquals(play, p.playWhenReady)
        assertEquals(1.5f, p.playbackParameters.speed, 0f)
    }

    @Test fun fullPlayerButtonsCrossFilesAndClampTheWholeBook() = withSession { a, p, _ ->
        Main::class.java.getDeclaredMethod("openSheet").apply { isAccessible = true }.invoke(a)
        val dialog = ShadowDialog.getLatestDialog()
        val all = views(dialog.window!!.decorView)
        val back = all.single { it.contentDescription == "Rewind 30 seconds" }
        val forward = all.single { it.contentDescription == "Forward 30 seconds" }
        position(p, 110.0); back.performClick(); expect(p, 80.0)
        position(p, 95.0); forward.performClick(); expect(p, 125.0)
        forward.performClick(); expect(p, 150.0)
        forward.performClick(); expect(p, 150.0)
        position(p, 10.0); back.performClick(); expect(p, 0.0)
        back.performClick(); expect(p, 0.0)
        position(p, 40.0); forward.performClick(); expect(p, 70.0)
        back.performClick(); expect(p, 40.0)
        p.playWhenReady = true
        position(p, 110.0); back.performClick(); expect(p, 80.0, true)
        position(p, 95.0); forward.performClick(); expect(p, 125.0, true)
        dialog.dismiss()
    }

    @Test fun remoteControllerCommandsUseTheSameRouteAndKeepPlayIntentAndSpeed() = withSession { _, p, remote ->
        assertTrue(remote.isCommandAvailable(Player.COMMAND_SEEK_BACK))
        assertTrue(remote.isCommandAvailable(Player.COMMAND_SEEK_FORWARD))
        for (play in listOf(false, true)) {
            p.playWhenReady = play
            position(p, 110.0); remote.seekBack(); expect(p, 80.0, play)
            position(p, 95.0); remote.seekForward(); expect(p, 125.0, play)
            remote.seekBack(); expect(p, 95.0, play)
            remote.seekBack(); expect(p, 65.0, play)
            position(p, 140.0); remote.seekForward(); expect(p, 150.0, play)
            position(p, 5.0); remote.seekBack(); expect(p, 0.0, play)
        }
    }

    @Test fun staleBookOrEmptyPlaylistCannotSeekAnotherTitle() = withSession { _, p, _ ->
        position(p, 110.0)
        Abs.now = Now("other", null, "Other", "", book.tracks)
        p.seekBack()
        assertEquals(1, p.currentMediaItemIndex)
        assertEquals(10_000L, p.currentPosition)
        Abs.now = null
        p.seekForward()
        assertEquals(10_000L, p.currentPosition)
        Abs.now = book
        p.clearMediaItems()
        p.seekBack()
        assertEquals(0, p.mediaItemCount)
    }
}
