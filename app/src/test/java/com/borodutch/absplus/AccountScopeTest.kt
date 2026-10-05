package com.borodutch.absplus

import android.os.Looper
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import com.sun.net.httpserver.HttpServer
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ActivityController
import org.robolectric.android.controller.ServiceController
import org.robolectric.shadows.ShadowDialog

/** Real Activity + MediaController + PlayerService/ExoPlayer and public Abs HTTP/cache.
 * Only the local server's response timing is controlled; no mocked account or player.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AccountScopeTest {
    private lateinit var activity: ActivityController<Main>
    private lateinit var service: ServiceController<PlayerService>
    private lateinit var controller: MediaController
    private lateinit var player: Player
    private val servers = mutableListOf<HttpServer>()
    private val executor = Executors.newCachedThreadPool()
    private lateinit var endpoint: String
    private val book = Now("book", null, "A book", "Author", listOf(Track("audio", ".wav", 4, 100.0, 0.0)))
    private class Gate(val path: String) {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        @Volatile var worker: Thread? = null
    }
    @Volatile private var gate: Gate? = null
    @Volatile private var newer = false

    private fun server(): String {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.executor = executor
        server.createContext("/") { x ->
            val path = x.requestURI.path
            val body = when (path) {
                "/login" -> {
                    val user = JSONObject(x.requestBody.bufferedReader().readText()).getString("username")
                    JSONObject().put("user", JSONObject().put("username", user).put("accessToken", user).put("refreshToken", "same-refresh")).toString()
                }
                "/auth/refresh" -> """{"user":{"username":"A","accessToken":"stale-rotated","refreshToken":"same-refresh"}}"""
                "/api/me" -> JSONObject().put("mediaProgress", JSONArray().put(JSONObject().put("libraryItemId", "book")
                    .put("currentTime", if (newer) 90 else 80).put("progress", .8).put("lastUpdate", 900000L)))
                    .put("bookmarks", JSONArray()).toString()
                "/api/me/progress/book" -> if (x.requestHeaders.getFirst("Authorization") == "Bearer linked")
                    """{"currentTime":70,"lastUpdate":1000}""" else """{"currentTime":10,"lastUpdate":100}"""
                "/api/items/book" -> JSONObject().put("id", "book").put("mediaType", "book").put("media", JSONObject()
                    .put("metadata", JSONObject().put("title", "A book"))
                    .put("tracks", JSONArray().put(JSONObject().put("ino", "audio").put("duration", 100)
                        .put("metadata", JSONObject().put("ext", ".wav").put("size", 4))))).toString()
                "/api/libraries" -> """{"libraries":[]}"""
                else -> """{}"""
            }
            gate?.takeIf { it.path == path }?.let {
                it.entered.countDown()
                check(it.release.await(10, TimeUnit.SECONDS))
            }
            val bytes = body.toByteArray()
            x.sendResponseHeaders(200, bytes.size.toLong())
            x.responseBody.use { it.write(bytes) }
        }
        server.start()
        servers += server
        return "http://127.0.0.1:" + server.address.port
    }

    @Before fun setup() {
        activity = Robolectric.buildActivity(Main::class.java).create()
        Abs.logout()
        endpoint = server()
        Abs.openConnection = { url ->
            gate?.takeIf { it.path == url.path }?.worker = Thread.currentThread()
            url.openConnection() as HttpURLConnection
        }
        login("A")
        service = Robolectric.buildService(PlayerService::class.java)
        service.create()
        val session = PlayerService::class.java.getDeclaredField("session").apply { isAccessible = true }.get(service.get()) as MediaSession
        player = session.player
        shadowOf(org.robolectric.RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(
            android.content.ComponentName(activity.get(), PlayerService::class.java),
            service.get().onBind(android.content.Intent(androidx.media3.session.MediaSessionService.SERVICE_INTERFACE)))
        activity.start().resume()
        val field = Main::class.java.getDeclaredField("ctl").apply { isAccessible = true }
        await { field.get(activity.get()) != null }
        controller = field.get(activity.get()) as MediaController
        // Local bytes keep these tests independent of ExoPlayer's HTTP loader.
        Abs.file(book.item, book.tracks.single()).apply { parentFile!!.mkdirs(); writeText("RIFF") }
    }

    private fun login(name: String, url: String = endpoint) {
        Abs.login(url, name, "fixture", true)
        Abs.startProgress(false) { 1000L }
    }
    private fun switch(mode: Int) {
        when (mode) {
            0 -> login("B")
            1 -> login("A", server())
            else -> { Abs.logout(); login("A") }
        }
    }
    private fun call(name: String, vararg args: Any?): Any? = Main::class.java.declaredMethods.single { it.name == name }
        .apply { isAccessible = true }.invoke(activity.get(), *args)
    private fun await(done: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!done() && System.nanoTime() < end) { shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(10) }
        assertTrue("Timed out", done())
    }
    private fun hold(path: String) = Gate(path).also { gate = it }
    private fun entered(g: Gate) { assertTrue(g.entered.await(5, TimeUnit.SECONDS)) }
    private fun release(g: Gate, deliver: Boolean = true) {
        g.release.countDown()
        val worker = g.worker!!
        worker.join(5000)
        assertFalse("Request worker did not finish", worker.isAlive)
        gate = null
        if (deliver) shadowOf(Looper.getMainLooper()).idle()
    }
    private fun pending() = JSONObject(Abs.p.getString("progressJournal", """{}""")!!).let { j ->
        j.keys().asSequence().map { j.getJSONObject(it) }.filter { it.optBoolean("dirty") }.toList()
    }
    private fun emptyPlayback() {
        assertNull(Abs.now)
        assertNull(Abs.loadNow())
        assertTrue(Abs.history().isEmpty())
        assertTrue(pending().isEmpty())
        assertEquals(0, player.mediaItemCount)
    }

    @After fun cleanup() {
        gate?.release?.countDown()
        activity.pause().stop().destroy()
        if (::service.isInitialized) service.destroy()
        Abs.logout()
        Abs.progressSync.close()
        servers.forEach { it.stop(0) }
        executor.shutdownNow()
        Abs.openConnection = { it.openConnection() as HttpURLConnection }
    }

    @Test fun delayedPlayPositionsCannotStartAfterUserServerOrSameNameRelogin() {
        repeat(3) { mode ->
            login("A")
            val g = hold("/api/me/progress/book")
            call("play", book, Abs.scope(playback = true))
            entered(g)
            switch(mode)
            release(g)
            emptyPlayback()
        }
    }

    @Test fun delayedCardMetadataCannotBeReboundToNewOwner() {
        repeat(3) { mode ->
            login("A")
            val g = hold("/api/items/book")
            call("playCard", Card("book", "A book", "Author"))
            entered(g)
            switch(mode)
            release(g)
            emptyPlayback()
            assertNull(Abs.cached("/api/items/book?expanded=1"))
        }
    }

    @Test fun delayedLifecycleRestoreCannotRebindSavedTitle() {
        repeat(3) { mode ->
            login("A")
            activity.pause().stop()
            Abs.saveNow(book)
            val g = hold("/api/me/progress/book")
            activity.start().resume()
            await { g.entered.count == 0L }
            switch(mode)
            release(g)
            emptyPlayback()
        }
    }

    @Test fun resumeChoiceAndQueuedStartRemainBoundToOriginalGeneration() {
        repeat(3) { mode ->
            login("A")
            Abs.login(endpoint, "linked", "fixture", false)
            Abs.setShares("book", setOf("linked"))
            call("play", book, Abs.scope(playback = true))
            await { ShadowDialog.getLatestDialog()?.isShowing == true }
            val dialog = ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog
            val captured = Abs.scope(playback = true)
            switch(mode)
            dialog.listView.performItemClick(null, 1, 1)
            call("start", book, 10.0, false, captured)
            shadowOf(Looper.getMainLooper()).idle()
            emptyPlayback()
            dialog.dismiss()
        }
    }

    @Test fun ongoingServiceEventsSurviveReauthButNotLogoutOrScopeSwitch() {
        repeat(3) { mode ->
            login("A")
            val captured = Abs.scope(playback = true)
            call("start", book, 20.0, false, captured)
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(1, player.mediaItemCount)
            val oldItem = player.currentMediaItem!!
            login("A") // request generation changes, playback identity does not
            assertEquals(captured, Abs.nowScope)
            service.get().progressListener(player).onIsPlayingChanged(true)
            assertEquals(1, pending().size)
            assertEquals("A", pending().single().getString("owner"))
            switch(mode)
            service.get().progressListener(player).onPlaybackStateChanged(Player.STATE_ENDED)
            shadowOf(Looper.getMainLooper()).idle()
            emptyPlayback()
            // Even the same title in the new account cannot accept old controller callbacks.
            Abs.bindPlayback(book, Abs.scope(playback = true))
            player.setMediaItem(oldItem)
            service.get().progressListener(player).onIsPlayingChanged(true)
            assertTrue(pending().isEmpty())
            player.clearMediaItems()
            Abs.clearPlayback()
        }
    }

    @Test fun delayedPublicGetCannotCacheOrObserveAnotherAccountsMe() {
        repeat(3) { mode ->
            login("A")
            val captured = Abs.scope()
            val g = hold("/api/me")
            var result: Result<String>? = null
            thread { result = runCatching { Abs.get("/api/me", captured) } }
            entered(g)
            switch(mode)
            Abs.push(book, 25.0, false)
            release(g)
            assertTrue(result!!.exceptionOrNull() is Expired)
            assertNull(Abs.cached("/api/me"))
            assertEquals(25.0, pending().single().getJSONObject("value").getDouble("currentTime"), 0.0)
            val stale = JSONObject().put("mediaProgress", JSONArray().put(JSONObject().put("libraryItemId", "book")
                .put("currentTime", 90).put("lastUpdate", 999999L)))
            assertTrue(runCatching { Abs.setMe(stale, captured) }.exceptionOrNull() is Expired)
            assertEquals(25.0, pending().single().getJSONObject("value").getDouble("currentTime"), 0.0)
        }
    }

    @Test fun loadRejectsDelayedNetworkAndAlreadyQueuedCachedRefreshDeliveries() {
        repeat(3) { mode ->
            for (queued in listOf(false, true)) {
                login("A")
                Abs.get("/api/me") // real cache, initial cached render is allowed
                newer = true
                val g = hold("/api/me")
                var renders = 0
                call("load", "/api/me", false, "progress", true, null, { _: JSONObject -> renders++ })
                assertEquals(1, renders)
                entered(g)
                if (queued) release(g, deliver = false)
                switch(mode)
                Abs.push(book, 25.0, false)
                if (!queued) release(g) else shadowOf(Looper.getMainLooper()).idle()
                assertEquals(1, renders)
                assertNull(Abs.cached("/api/me"))
                assertEquals(25.0, pending().single().getJSONObject("value").getDouble("currentTime"), 0.0)
                newer = false
            }
        }
    }

    @Test fun libraryRejectsQueuedMembershipAfterAccountGenerationChanges() {
        repeat(3) { mode ->
            login("A")
            Abs.p.edit().putString("lib", "original").commit()
            val g = hold("/api/libraries")
            call("tab", 1)
            entered(g)
            release(g, deliver = false) // HTTP/cache succeeded; UI delivery is still queued.
            switch(mode)
            Abs.p.edit().putString("lib", "original").commit()
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals("original", Abs.p.getString("lib", null))
            assertNull(Abs.cached("/api/libraries"))
        }
    }

    @Test fun successfulSameAccountReauthInvalidatesRequestsNotPlaybackIdentity() {
        val playback = Abs.scope(playback = true)
        val request = Abs.scope()
        val g = hold("/api/me")
        var result: Result<String>? = null
        thread { result = runCatching { Abs.api("GET", "/api/me") } }
        entered(g)
        login("A")
        release(g)
        assertTrue(result!!.exceptionOrNull() is Expired)
        assertEquals(playback, Abs.scope(playback = true))
        assertNotEquals(request, Abs.scope())
        assertTrue(runCatching { Abs.setMe(JSONObject().put("mediaProgress", JSONArray()), request) }.exceptionOrNull() is Expired)
    }

    @Test fun playbackRefreshUsesReauthenticatedCredentialsWithoutReinsertingOldResponse() {
        val captured = Abs.scope(playback = true)
        val g = hold("/auth/refresh")
        var result: Result<String>? = null
        thread { result = runCatching { Abs.token(force = true, captured = captured) } }
        entered(g)
        login("A")
        release(g)
        assertEquals("A", result!!.getOrThrow())
        assertEquals("A", JSONObject(Abs.p.getString("acct:A", "{}")!!).getString("a"))
        assertEquals(captured, Abs.scope(playback = true))
    }

    @Test fun reauthDuringCardPreparationDoesNotLogOutOrDisturbExistingPlayback() {
        call("start", book, 20.0, false, Abs.scope(playback = true))
        shadowOf(Looper.getMainLooper()).idle()
        val content = Main::class.java.getDeclaredField("content").apply { isAccessible = true }
            .get(activity.get()) as android.widget.FrameLayout
        val page = content.getChildAt(0)
        val g = hold("/api/items/book")
        call("playCard", Card("book", "A book", "Author"))
        entered(g)
        login("A")
        release(g)
        assertSame(page, content.getChildAt(0))
        assertSame(book, Abs.now)
        assertEquals(1, player.mediaItemCount)
    }

    @Test fun oldRefreshCannotReinsertIdenticalCredentialsAfterSameNameLogin() {
        val g = hold("/auth/refresh")
        var result: Result<String>? = null
        thread { result = runCatching { Abs.token(force = true) } }
        entered(g)
        Abs.logout()
        login("A") // deliberately identical token bytes and server/username
        release(g)
        assertTrue(result!!.exceptionOrNull() is Expired)
        assertEquals("A", JSONObject(Abs.p.getString("acct:A", """{}""")!!).getString("a"))
    }

    private fun visibleTexts(): List<String> {
        fun walk(v: android.view.View): List<android.view.View> = if (v.visibility != android.view.View.VISIBLE) emptyList()
            else listOf(v) + if (v is android.view.ViewGroup) (0 until v.childCount).flatMap { walk(v.getChildAt(it)) } else emptyList()
        return walk(activity.get().window.decorView).filterIsInstance<android.widget.TextView>().map { it.text.toString() }
    }

    @Test fun reauthClearsStaleLoadWithoutExpiryAndFreshLoadUpdatesPersistedProgress() {
        val g = hold("/api/me")
        var renders = 0
        call("load", "/api/me", false, "progress", true, null, { _: JSONObject -> renders++ })
        assertTrue("Loading progress…" in visibleTexts())
        entered(g)
        val playback = Abs.scope(playback = true)
        login("A") // Same strings, different request generation.
        release(g)
        assertEquals(0, renders)
        assertFalse("Loading progress…" in visibleTexts())
        assertFalse("Session expired. Sign in again." in visibleTexts())
        assertEquals(playback, Abs.scope(playback = true))
        assertNull(Abs.cached("/api/me"))
        call("load", "/api/me", false, "progress", true, null, { _: JSONObject -> renders++ })
        await { renders == 1 }
        assertFalse("Loading progress…" in visibleTexts())
        Abs.startProgress(false) { 1000L }
        Abs.offline = true
        assertEquals(80.0, Abs.positions(book).first().time, 0.0)
        Abs.offline = false
    }

    @Test fun staleAudioCompletionCannotClearNewSameTitleRequestForAnotherAccount() {
        val first = hold("/api/me/progress/book")
        call("play", book, Abs.scope(playback = true))
        entered(first)
        login("B")
        val second = hold("/api/me/progress/book")
        call("play", book, Abs.scope(playback = true))
        entered(second)
        release(first)
        gate = second
        assertTrue("Loading audio…" in visibleTexts())
        val pending = Main::class.java.getDeclaredField("pendingPlay").apply { isAccessible = true }
        assertEquals("book", pending.get(activity.get()))
        assertNull(Abs.now)
        release(second)
        await { Abs.now != null }
        assertEquals("B", Abs.nowScope!!.owner)
        assertNull(pending.get(activity.get()))
        assertFalse("Loading audio…" in visibleTexts())
        assertTrue(pending().all { it.getString("owner") == "B" })
    }

    @Test fun offlinePreparationUsesJournalWithoutNetworkAndNavigationCancelsQueuedStart() {
        Abs.push(book, 42.0, false)
        Abs.startProgress(false) { 1000L }
        val original = Abs.openConnection
        val requests = java.util.concurrent.atomic.AtomicInteger()
        Abs.openConnection = { requests.incrementAndGet(); throw java.io.IOException("must stay offline") }
        Abs.offline = true
        try {
            call("shelf", "Offline root", emptyList<Card>(), 1f)
            call("push", { call("shelf", "Offline audio", emptyList<Card>(), 1f) })
            call("play", book, Abs.scope(playback = true))
            assertTrue("Loading audio…" in visibleTexts())
            activity.get().onBackPressedDispatcher.onBackPressed()
            shadowOf(Looper.getMainLooper()).idle()
            assertNull(Abs.now)
            assertFalse("Loading audio…" in visibleTexts())
            call("push", { call("shelf", "Offline audio", emptyList<Card>(), 1f) })
            call("play", book, Abs.scope(playback = true))
            await { Abs.now != null }
            assertEquals(42_000L, controller.currentPosition)
            assertEquals(0, requests.get())
            assertEquals("A", Abs.nowScope!!.owner)
        } finally {
            Abs.openConnection = original
            Abs.offline = false
        }
    }
}
