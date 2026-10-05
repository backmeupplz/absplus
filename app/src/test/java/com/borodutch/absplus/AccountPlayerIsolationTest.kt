package com.borodutch.absplus

import android.content.ComponentName
import android.content.Intent
import android.os.Looper
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.BitmapDrawable
import android.widget.ImageView
import java.io.ByteArrayOutputStream
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import com.sun.net.httpserver.HttpServer
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AccountPlayerIsolationTest {
    private class Host : AutoCloseable {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val pool = Executors.newCachedThreadPool()
        val url get() = "http://127.0.0.1:" + server.address.port
        @Volatile var delayLogin = false
        @Volatile var rejectRefresh = false
        @Volatile var idOverride: String? = null
        @Volatile var coverColor = Color.RED
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        @Volatile var denied = CountDownLatch(1)
        init {
            server.executor = pool
            server.createContext("/") { x ->
                val data = x.requestBody.bufferedReader().use { it.readText() }
                var code = 200
                if (x.requestURI.path.endsWith("/cover")) {
                    val png = ByteArrayOutputStream().also { out ->
                        Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888).apply { eraseColor(coverColor) }
                            .compress(Bitmap.CompressFormat.PNG, 100, out)
                    }.toByteArray()
                    x.sendResponseHeaders(200, png.size.toLong())
                    x.responseBody.use { it.write(png) }
                    return@createContext
                }
                val body = when (x.requestURI.path) {
                    "/login" -> {
                        if (delayLogin) { entered.countDown(); release.await(10, TimeUnit.SECONDS) }
                        val name = JSONObject(data).getString("username")
                        if (JSONObject(data).optString("password") == "bad") code = 401
                        JSONObject().put("user", JSONObject().put("id", idOverride ?: "id-" + name).put("username", name).put("accessToken", name)).toString()
                    }
                    "/auth/refresh" -> { if (rejectRefresh) code = 401; "{}" }
                    "/api/items/book" -> {
                        if (x.requestHeaders.getFirst("Authorization") == "Bearer B") {
                            code = 403; denied.countDown(); "{}"
                        } else """{"id":"book","mediaType":"book","media":{"metadata":{"title":"A private title","authorName":"A author"},"tracks":[{"ino":"1","duration":1,"metadata":{"ext":".wav","size":16044}}]}}"""
                    }
                    "/api/me" -> """{"mediaProgress":[],"bookmarks":[]}"""
                    "/api/me/items-in-progress" -> """{"libraryItems":[]}"""
                    else -> "{}"
                }.toByteArray()
                x.sendResponseHeaders(code, body.size.toLong())
                x.responseBody.use { it.write(body) }
            }
            server.start()
        }
        fun login(name: String) = Abs.login(url, name, "fixture", true)
        override fun close() { release.countDown(); server.stop(0); pool.shutdownNow() }
    }
    private fun Main.call(name: String, vararg args: Any) = Main::class.java.declaredMethods.single { it.name == name }
        .apply { isAccessible = true }.invoke(this, *args)
    private fun views(v: View): List<View> = listOf(v) + if (v is ViewGroup) (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()
    private fun drainUntil(check: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!check() && System.nanoTime() < deadline) { shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(10)); Thread.sleep(10) }
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(check())
    }
    private val track = Track("1", ".wav", 16044, 1.0, 0.0)
    private val now = Now("book", null, "A private title", "A author", listOf(track))
    private fun seed(): File {
        Abs.get("/api/items/book?expanded=1")
        // Valid local PCM WAV: exercise Media3's actual local-file source, not a fake player.
        val wav = ByteBuffer.allocate(16044).order(ByteOrder.LITTLE_ENDIAN)
        wav.put("RIFF".toByteArray()).putInt(16036).put("WAVEfmt ".toByteArray()).putInt(16)
            .putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16)
            .put("data".toByteArray()).putInt(16000)
        return Abs.file("book", track).apply { parentFile!!.mkdirs(); writeBytes(wav.array()) }
    }

    @Test fun persistentDownloadAndMiniPlayerCoversRebindSameItemAcrossAccountsAndHosts() {
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        Host().use { a -> Host().use { b ->
            a.login("A")
            val service = Robolectric.buildService(PlayerService::class.java).create()
            val component = ComponentName(RuntimeEnvironment.getApplication(), PlayerService::class.java)
            val binder = service.get().onBind(Intent("androidx.media3.session.MediaSessionService").setComponent(component))
            shadowOf(RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(component, binder)
            val session = PlayerService::class.java.getDeclaredField("session").apply { isAccessible = true }.get(service.get()) as MediaSession
            val player = (session.player as BookPlayer).wrappedPlayer as ExoPlayer
            val activity = Robolectric.buildActivity(Main::class.java).create().start().resume().visible()
            val main = activity.get()
            fun cover(field: String) = Main::class.java.getDeclaredField(field).apply { isAccessible = true }.get(main) as ImageView
            val mini = cover("miniCover"); val download = cover("dlCover")
            fun color(v: ImageView) = (v.drawable as? BitmapDrawable)?.bitmap?.getPixel(0, 0)
            fun render(expected: Int) {
                drainUntil { Main::class.java.getDeclaredField("ctl").apply { isAccessible = true }.get(main) != null }
                Abs.now = now
                // Keep a real queue entry without preparing network playback.
                player.setMediaItem(MediaItem.Builder().setUri("http://127.0.0.1/unused").setMediaId("book#0").build())
                Dl.jobs.clear(); Dl.jobs += Dl.Job(now)
                drainUntil { (Main::class.java.getDeclaredField("ctl").apply { isAccessible = true }.get(main) as MediaController).mediaItemCount == 1 }
                main.call("updateDl"); main.call("updatePlayer")
                try { drainUntil { color(mini) == expected && color(download) == expected } }
                catch (e: AssertionError) { throw AssertionError("expected=$expected mini=${color(mini)} download=${color(download)} miniTag=${mini.tag} dlTag=${download.tag} now=${Abs.now}", e) }
                assertSame(mini, cover("miniCover")); assertSame(download, cover("dlCover"))
            }
            try {
                render(Color.RED)
                a.coverColor = Color.BLUE; a.login("B")
                render(Color.BLUE) // same host, different account, same item and persistent views
                b.coverColor = Color.GREEN; b.login("B")
                render(Color.GREEN) // different host, same account name and item
            } finally { activity.pause().stop().destroy(); service.destroy(); Abs.logout() }
        } }
    }

    @Test fun sameServerForbiddenAccountCannotRenderOrPlayRetainedOwnerBytes() {
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        Host().use { host ->
            host.login("A")
            val bytes = seed()
            val root = Abs.mediaDir
            val serverRoot = root.parentFile!!.parentFile!!
            val quarantined = File(serverRoot, "audio/legacy/1.wav").apply { parentFile!!.mkdirs(); writeBytes(bytes.readBytes()) }
            val unscoped = File(Abs.dir, "legacy/1.wav").apply { parentFile!!.mkdirs(); writeBytes(bytes.readBytes()) }
            val legacyJSON = File(RuntimeEnvironment.getApplication().filesDir, "json/_api_items_book_expanded_1").apply {
                parentFile!!.mkdirs(); writeText(Abs.cached("/api/items/book?expanded=1")!!)
            }
            Abs.logout(); host.login("B")
            assertNull(Abs.cached("/api/items/book?expanded=1"))
            assertFalse(Abs.done("book", track)); assertFalse(Abs.downloaded("book"))
            assertTrue(Abs.downloads().isEmpty()); assertEquals("http", Abs.uri("book", track).scheme)
            assertEquals(403, (runCatching { Abs.get("/api/items/book?expanded=1") }.exceptionOrNull() as HttpErr).code)
            shadowOf(RuntimeEnvironment.getApplication()).declareComponentUnbindable(ComponentName(RuntimeEnvironment.getApplication(), PlayerService::class.java))
            val activity = Robolectric.buildActivity(Main::class.java).create().start().resume()
            try {
                host.denied = CountDownLatch(1)
                activity.get().call("item", "book")
                assertTrue(host.denied.await(5, TimeUnit.SECONDS))
                shadowOf(Looper.getMainLooper()).idle()
                assertTrue(views(activity.get().window.decorView).filterIsInstance<TextView>().none { it.text.contains("A private title") })
                activity.get().call("playCard", Card("book", "", ""))
                drainUntil { views(activity.get().window.decorView).filterIsInstance<TextView>().any { it.text == "Couldn't load audio." } }
                assertNull(Abs.now)
            } finally { activity.pause().stop().destroy() }
            assertEquals(16044, bytes.length().toInt())
            host.login("A")
            assertEquals(root, Abs.mediaDir); assertEquals("A private title", Abs.cachedCard("book").title)
            assertTrue(Abs.done("book", track)); assertEquals("file", Abs.uri("book", track).scheme)
            assertFalse(Abs.done("legacy", track)); assertTrue(quarantined.exists()); assertTrue(unscoped.exists())
            assertTrue(legacyJSON.readText().contains("A private title"))
            Abs.logout()
        }
    }

    @Test fun leftoverSessionJsonNeverCrossesAccountOrReauthentication() {
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        // Match a real process restart: preferences and files must come from this test's context,
        // not the singleton retained from a previous Robolectric sandbox.
        Abs::class.java.getDeclaredField("p").apply { isAccessible = true }.set(null, null)
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        Host().use { host ->
            fun cache(path: String) = Abs::class.java.getDeclaredMethod("cacheFile", String::class.java)
                .apply { isAccessible = true }.invoke(Abs, path) as File
            host.login("A")
            val path = "/api/me"
            Abs.get(path)
            val old = cache(path)
            val data = old.readText()
            host.login("B")
            // Recreate leftover bytes as if best-effort cleanup could not remove them.
            old.writeText(data)
            assertNotEquals(old.parentFile, cache(path).parentFile)
            assertNull(Abs.cached(path)); assertEquals(data, old.readText())
            host.login("A")
            assertNotEquals(old.parentFile, cache(path).parentFile)
            assertNull(Abs.cached(path)); assertEquals(data, old.readText())
            Abs.get(path)
            val current = cache(path)
            Abs.token(force = false)
            assertEquals(current, cache(path))
            // A process restart preserves the established login's namespace.
            Abs::class.java.getDeclaredField("p").apply { isAccessible = true }.set(null, null)
            Abs.init(RuntimeEnvironment.getApplication())
            assertEquals(current, cache(path)); assertNotNull(Abs.cached(path))
            Abs.logout()
        }
    }

    @Test fun expiredSessionUiKeepsAuthorizedPlaybackThroughFailureCancellationAndSameOwnerLogin() {
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        Host().use { host ->
            host.login("A"); seed(); Abs.startProgress(false)
            val service = Robolectric.buildService(PlayerService::class.java).create()
            val component = ComponentName(RuntimeEnvironment.getApplication(), PlayerService::class.java)
            val binder = service.get().onBind(Intent("androidx.media3.session.MediaSessionService").setComponent(component))
            shadowOf(RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(component, binder)
            val session = PlayerService::class.java.getDeclaredField("session").apply { isAccessible = true }.get(service.get()) as MediaSession
            val player = (session.player as BookPlayer).wrappedPlayer as ExoPlayer
            var activity = Robolectric.buildActivity(Main::class.java).create().start().resume().visible()
            fun connect() = drainUntil { Main::class.java.getDeclaredField("ctl").apply { isAccessible = true }.get(activity.get()) != null }
            fun signIn(password: String) {
                val fields = views(activity.get().window.decorView).filterIsInstance<com.google.android.material.textfield.TextInputLayout>()
                fields.single { it.hint == "Username" }.editText!!.setText("A")
                fields.single { it.hint == "Password" }.editText!!.setText(password)
                views(activity.get().window.decorView).filterIsInstance<TextView>().single { it.text == "Sign in" }.performClick()
            }
            try {
                connect()
                activity.get().call("start", now, 0.0, false, Abs.scope(playback = true))
                drainUntil { player.playbackState == Player.STATE_READY || player.playerError != null }
                assertNull(player.playerError)
                val scope = Abs.nowScope!!
                val media = player.currentMediaItem!!
                player.seekTo(350)
                // Real HTTP refresh expiry exposes the page-owned Sign in action.
                val stored = JSONObject(Abs.p.getString("acct:A", null)!!).put("a", "x.eyJleHAiOjF9.x")
                Abs.p.edit().putString("acct:A", stored.toString()).commit()
                host.rejectRefresh = true
                activity.get().call("home")
                drainUntil { views(activity.get().window.decorView).filterIsInstance<TextView>().any { it.text == "Session expired. Sign in again." } }
                views(activity.get().window.decorView).filterIsInstance<TextView>().first { it.text == "Sign in" }.performClick()
                drainUntil { Abs.loginPending }
                assertTrue(views(activity.get().window.decorView).filterIsInstance<TextView>().any { it.text == "Sign in" })
                assertEquals(media, player.currentMediaItem); assertEquals(350L, player.currentPosition)
                PlayerService.invalidateSession()
                assertEquals(1, player.mediaItemCount)
                // Real player callbacks still checkpoint during authentication (not a direct Abs.push).
                player.play()
                drainUntil { player.isPlaying }
                // ExoPlayer masks isPlaying synchronously, before its playback thread applies
                // pause. Hold that thread to exercise this ordering instead of racing it.
                val playbackHeld = CountDownLatch(1)
                val releasePlayback = CountDownLatch(1)
                val barrier = player.createMessage { _, _ ->
                    playbackHeld.countDown()
                    check(releasePlayback.await(5, TimeUnit.SECONDS))
                }.send()
                try {
                    assertTrue(playbackHeld.await(5, TimeUnit.SECONDS))
                    player.pause()
                    assertFalse(player.isPlaying)
                } finally { releasePlayback.countDown() }
                assertTrue(barrier.blockUntilDelivered(5_000))
                // This message follows pause on the playback looper. Drain the resulting
                // application callbacks before sampling the checkpoint to preserve.
                assertTrue(player.createMessage { _, _ -> }.send().blockUntilDelivered(5_000))
                shadowOf(Looper.getMainLooper()).idle()
                val checkpoint = Abs.pos(player, now)
                assertEquals(checkpoint, Abs.progressSync.local()[now.key]!!.getDouble("currentTime"), 0.001)
                activity.get().call("start", Now("other", null, "Other", "", now.tracks), 0.0, true, scope)
                assertEquals(media, player.currentMediaItem)
                signIn("bad")
                drainUntil { views(activity.get().window.decorView).filterIsInstance<TextView>().any { it.text == "Sign in" && it.isEnabled } }
                assertTrue(Abs.loginPending); assertEquals(scope, Abs.nowScope); assertEquals(media, player.currentMediaItem)
                host.delayLogin = true
                signIn("fixture")
                assertTrue(host.entered.await(5, TimeUnit.SECONDS))
                val attempt = Main::class.java.getDeclaredField("loginAttempt").apply { isAccessible = true }.get(activity.get()) as Abs.LoginAttempt
                activity.pause().stop().destroy() // cancels the actual UI-owned attempt
                assertTrue(attempt.cancelled)
                activity = Robolectric.buildActivity(Main::class.java).create().start().resume().visible(); connect()
                assertTrue(Abs.loginPending); assertEquals(media, player.currentMediaItem)
                host.delayLogin = false; host.rejectRefresh = false; host.release.countDown()
                signIn("fixture")
                drainUntil { !Abs.loginPending }
                Abs.startProgress(false)
                assertEquals(scope, Abs.nowScope); assertEquals(media, player.currentMediaItem)
                assertEquals(checkpoint, Abs.pos(player, now), 0.001)
                assertEquals(checkpoint, Abs.progressSync.local()[now.key]!!.getDouble("currentTime"), 0.001)
                // Same username is insufficient when the immutable identity was replaced.
                activity.get().call("login"); host.idOverride = "replacement-owner"
                signIn("fixture")
                drainUntil { !Abs.loginPending && player.mediaItemCount == 0 }
                assertNull(Abs.nowScope); assertTrue(Abs.progressSync.local().isEmpty())
                assertFalse(player.isPlaying)
            } finally { activity.pause().stop().destroy(); service.destroy(); Abs.logout() }
        }
    }

    @Test fun realServiceClearsLocalQueueOnCommitAndLoginSurvivesLifecycle() {
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        Host().use { host ->
            host.login("A"); val bytes = seed()
            val oldEpoch = Abs.scope(playback = true).generation
            val service = Robolectric.buildService(PlayerService::class.java).create()
            val component = ComponentName(RuntimeEnvironment.getApplication(), PlayerService::class.java)
            val binder = service.get().onBind(Intent("androidx.media3.session.MediaSessionService").setComponent(component))
            shadowOf(RuntimeEnvironment.getApplication()).setComponentNameAndServiceForBindService(component, binder)
            val session = PlayerService::class.java.getDeclaredField("session").apply { isAccessible = true }.get(service.get()) as MediaSession
            val player = (session.player as BookPlayer).wrappedPlayer as ExoPlayer
            val future = MediaController.Builder(RuntimeEnvironment.getApplication(), session.token).buildAsync()
            drainUntil { future.isDone }
            val controller = future.get()
            var activity = Robolectric.buildActivity(Main::class.java).create().start().resume()
            fun connect() {
                drainUntil { Main::class.java.getDeclaredField("ctl").apply { isAccessible = true }.get(activity.get()) != null }
            }
            try {
                connect()
                activity.get().call("start", now, 0.0, false, Abs.scope(playback = true))
                drainUntil { player.mediaItemCount == 1 }
                assertEquals("file", player.currentMediaItem!!.localConfiguration!!.uri.scheme)
                drainUntil { player.playbackState == Player.STATE_READY || player.playerError != null }
                assertNull(player.playerError)
                activity.get().call("login")
                assertEquals(1, player.mediaItemCount) // authorized queue survives authentication
                // Explicitly empty it to retain the no-new/no-restore assertions below.
                player.clearMediaItems()
                drainUntil { player.mediaItemCount == 0 }
                assertTrue(Abs.loginPending)
                host.delayLogin = true
                val pending = thread { host.login("B") }
                assertTrue(host.entered.await(5, TimeUnit.SECONDS))
                activity.pause().stop().start().resume(); connect()
                activity.get().call("restore")
                activity.get().call("start", now, 0.0, true, Abs.scope(playback = true))
                shadowOf(Looper.getMainLooper()).idle()
                assertEquals(0, player.mediaItemCount)
                activity.pause().stop().destroy()
                activity = Robolectric.buildActivity(Main::class.java).create().start().resume(); connect()
                assertTrue(views(activity.get().window.decorView).filterIsInstance<TextView>().any { it.text == "Sign in" })
                activity.get().call("restore")
                assertEquals(0, player.mediaItemCount)
                // A stale local queue must be invalidated by the service at commit even without an Activity/controller.
                player.setMediaItem(MediaItem.Builder().setUri(android.net.Uri.fromFile(bytes)).setMediaId("book#0").build())
                player.prepare()
                assertEquals(1, player.mediaItemCount)
                activity.pause().stop().destroy()
                host.release.countDown(); pending.join(5000); assertFalse(pending.isAlive)
                drainUntil { player.mediaItemCount == 0 }
                assertNull(Abs.now); assertFalse(player.isPlaying); assertTrue(bytes.exists())
                controller.setMediaItem(MediaItem.Builder().setUri(android.net.Uri.fromFile(bytes))
                    .setCustomCacheKey(oldEpoch.toString()).setMediaId("book#0").build())
                controller.prepare(); controller.play()
                // Drain the real controller command path; a delayed A command cannot resurrect its file.
                repeat(10) { shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(10) }
                assertEquals(0, player.mediaItemCount); assertFalse(player.isPlaying)
            } finally {
                if (!activity.get().isDestroyed) activity.pause().stop().destroy()
                controller.release(); service.destroy(); Abs.logout()
            }
        }
    }
}
