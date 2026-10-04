package com.borodutch.absplus

import android.content.Intent
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.google.android.material.slider.Slider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

/** Real views and an in-process media session; never connects to an account or media server. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AccessibilityTest {
    private lateinit var activity: Main
    private lateinit var controller: org.robolectric.android.controller.ActivityController<Main>

    @Before fun setUp() {
        controller = Robolectric.buildActivity(Main::class.java).create()
        activity = controller.get()
        Abs.p.edit().clear().putString("server", "http://127.0.0.1:1").commit()
        Abs.offline = false
        Abs.now = null
        Dl.jobs.clear()
    }

    @After fun tearDown() {
        ShadowDialog.getLatestDialog()?.dismiss()
        Abs.now = null
        Dl.jobs.clear()
        Abs.file("pod", Track("two", ".mp3", 7, 60.0, 0.0)).delete()
        Abs.p.edit().clear().commit()
        controller.destroy()
    }

    private fun call(name: String, vararg args: Any?): Any? = Main::class.java.declaredMethods
        .single { it.name == name && it.parameterCount == args.size }.apply { isAccessible = true }.invoke(activity, *args)
    private fun field(name: String) = Main::class.java.getDeclaredField(name).apply { isAccessible = true }
    private fun views(v: View): List<View> = listOf(v) + if (v is ViewGroup)
        (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()
    private fun root() = field("content").get(activity) as View
    private fun named(root: View, name: String) = views(root).single { it.contentDescription == name }
    private fun layout(v: View) {
        v.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1800, View.MeasureSpec.EXACTLY))
        v.layout(0, 0, 1080, 1800)
    }

    @Test fun aboutLinksLaunchExactUrlsAndVersionComesFromInstalledPackage() {
        val installed = activity.packageManager.getPackageInfo(activity.packageName, 0)
        installed.versionName = "9.8.fixture"
        installed.setLongVersionCode(987L)
        shadowOf(activity.packageManager).installPackage(installed)
        call("settings")
        val texts = views(root()).filterIsInstance<TextView>()
        assertTrue(texts.any { it.text == "About" })
        assertTrue(texts.any { it.text == "Version 9.8.fixture (987)" })
        listOf("Website" to "https://absplus.app", "Source code" to "https://github.com/backmeupplz/absplus",
            "Privacy policy" to "https://absplus.app/privacy/").forEach { (label, url) ->
            texts.single { it.text == label }.performClick()
            val intent = shadowOf(activity).nextStartedActivity
            assertEquals(Intent.ACTION_VIEW, intent.action)
            assertEquals(url, intent.dataString)
        }
    }

    @Test fun favoriteActionChangesOnTheSameViewAndShareHasAName() {
        val rv = RecyclerView(activity).apply { layoutManager = LinearLayoutManager(activity) }
        val item = JSONObject().put("id", "fixture-book").put("mediaType", "book").put("media", JSONObject()
            .put("metadata", JSONObject().put("title", "A book")).put("tracks", JSONArray()))
        call("renderItem", rv, item)
        layout(rv)
        val favorite = named(rv, "Add to favorites")
        favorite.performClick()
        assertFalse(favorite.isEnabled)
        assertEquals("Remove from favorites", favorite.contentDescription)
        assertTrue(Abs.isFav("fixture-book"))
        // The local sync fails against the closed loopback port. The actual UI
        // callback must restore the same button before another action is allowed.
        val until = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(8)
        while (!favorite.isEnabled && System.nanoTime() < until) {
            Thread.sleep(15)
            shadowOf(Looper.getMainLooper()).idle()
        }
        assertTrue("Favorite action must recover after sync failure", favorite.isEnabled)
        favorite.performClick()
        assertEquals("Add to favorites", favorite.contentDescription)
        assertFalse(Abs.isFav("fixture-book"))
        named(rv, "Share progress").performClick()
        assertTrue(views(ShadowDialog.getLatestDialog().window!!.decorView).filterIsInstance<TextView>()
            .any { it.text == "Share progress of “A book”" })
    }

    @Test fun linkedAccountActionsNameTheCorrectAccount() {
        Abs.p.edit().putString("acct:Alice", "{}").putString("acct:Bob", "{}").commit()
        call("settings")
        named(root(), "Unlink account Alice").performClick()
        val dialog = ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog
        assertTrue(views(dialog.window!!.decorView).filterIsInstance<TextView>().any { it.text.startsWith("Unlink Alice?") })
        dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE).performClick()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf("Bob"), Abs.accounts())
        named(root(), "Unlink account Bob")
    }

    @Test fun recycledEpisodeRowsReplacePlayAndEveryDownloadActionName() {
        val first = Now("pod", "one", "First episode", "Podcast", listOf(Track("one", ".mp3", 7, 60.0, 0.0)))
        val second = Now("pod", "two", "Second episode", "Podcast", listOf(Track("two", ".mp3", 7, 60.0, 0.0)))
        val row = call("episodeRow") as View
        call("bindEpisode", row, first, null)
        named(row, "Play First episode")
        named(row, "Download First episode")
        Dl.jobs += Dl.Job(second)
        call("bindEpisode", row, second, null)
        named(row, "Play Second episode")
        named(row, "Cancel download of Second episode")
        assertFalse(views(row).any { it.contentDescription?.contains("First episode") == true })
        Dl.jobs.clear()
        Abs.file(second.item, second.tracks.single()).apply { parentFile!!.mkdirs(); writeText("fixture") }
        call("bindEpisode", row, second, null)
        named(row, "Remove download of Second episode").performClick()
        val dialog = ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog
        assertTrue(views(dialog.window!!.decorView).filterIsInstance<TextView>().any { it.text.contains("Second episode") })
        dialog.dismiss()
        call("bindEpisode", row, first, null)
        named(row, "Download First episode")
    }

    @Test fun listActionsNameTheirTitleAndQueueCancelNamesItsEpisode() {
        val card = Card("", "A title", "Author")
        val play = call("listRow", card, "", { }, { }) as View
        named(play, "Play A title")
        val remove = call("listRow", card, "", R.drawable.i_delete, { }, { }) as View
        named(remove, "Remove download of A title")
        val n = Now("pod", "one", "Queued episode", "Podcast", listOf(Track("one", ".mp3", 7, 60.0, 0.0)))
        val queue = call("jobRow", Dl.Job(n)) as Pair<*, *>
        named(queue.first as View, "Cancel download of Queued episode")
    }

    private class FixturePlayer : SimpleBasePlayer(Looper.getMainLooper()) {
        var playing = false
        var speed = 1f
        override fun getState(): State = State.Builder()
            .setAvailableCommands(Player.Commands.Builder().addAllCommands().build())
            .setPlaylist(listOf(MediaItemData.Builder("fixture").setMediaItem(MediaItem.fromUri("file:///fixture.mp3")).setDurationUs(120_000_000).build()))
            .setCurrentMediaItemIndex(0)
            .setContentPositionMs(30_000)
            .setPlaybackState(Player.STATE_READY)
            .setPlayWhenReady(playing, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackParameters(PlaybackParameters(speed)).build()
        override fun handleRelease(): com.google.common.util.concurrent.ListenableFuture<*> =
            com.google.common.util.concurrent.Futures.immediateVoidFuture()
        fun update(playing: Boolean, speed: Float = 1f) {
            this.playing = playing
            this.speed = speed
            invalidateState()
        }
    }

    @Test fun miniAndExpandedPlayerFollowPlaybackStateAndLabelSpeedAndSeek() {
        val player = FixturePlayer()
        val session = MediaSession.Builder(activity, player).build()
        val future = MediaController.Builder(activity, session.token).buildAsync()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(future.isDone)
        val media = future.get()
        field("ctl").set(activity, media)
        Abs.now = Now("fixture-book", null, "A book", "Author", listOf(Track("audio", ".mp3", 0, 120.0, 0.0)))
        try {
            call("updatePlayer")
            val mini = field("miniPlay").get(activity) as MaterialButton
            assertEquals("Play", mini.contentDescription)
            call("openSheet")
            val sheet = ShadowDialog.getLatestDialog().window!!.decorView
            val expanded = named(sheet, "Play")
            named(sheet, "Rewind 30 seconds")
            named(sheet, "Forward 30 seconds")
            val slider = named(sheet, "Playback position") as Slider
            assertEquals(30f, slider.value, 0f)
            named(sheet, "Playback speed, 1×")
            player.update(true, 1.5f)
            shadowOf(Looper.getMainLooper()).idle()
            call("updatePlayer")
            assertEquals("Pause", mini.contentDescription)
            assertEquals("Pause", expanded.contentDescription)
            named(sheet, "Playback speed, 1.5×")
            player.update(false)
            shadowOf(Looper.getMainLooper()).idle()
            call("updatePlayer")
            assertEquals("Play", mini.contentDescription)
            assertEquals("Play", expanded.contentDescription)
        } finally {
            field("ctl").set(activity, null)
            media.release()
            session.release()
            player.release()
        }
    }
}
