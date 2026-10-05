package com.borodutch.absplus

import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleRegistry
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Loopback-only HTTP + real Main screens, controls, navigation and layouts. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LoadingTest {
    private fun Main.call(name: String, vararg args: Any) = Main::class.java.declaredMethods.single { it.name == name }
        .apply { isAccessible = true }.invoke(this, *args)
    private fun Main.content() = Main::class.java.getDeclaredField("content").apply { isAccessible = true }.get(this) as FrameLayout
    private fun Main.connectivityTick() {
        (Main::class.java.getDeclaredField("tick").apply { isAccessible = true }.get(this) as Runnable).run()
    }
    private fun views(v: View): List<View> = listOf(v) + if (v is ViewGroup) (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()
    private fun visible(v: View): Boolean = v.visibility == View.VISIBLE && ((v.parent as? View)?.let(::visible) ?: true)
    private fun Main.has(s: String) = views(content()).filterIsInstance<TextView>().any { it.text.toString() == s && visible(it) }
    private fun Main.button(s: String) = views(content()).filterIsInstance<MaterialButton>().first { it.text.toString() == s && visible(it) }
    private fun layout(v: View) { v.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1800, View.MeasureSpec.EXACTLY)); v.layout(0, 0, 1080, 1800) }
    private fun await(check: () -> Boolean) {
        val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
        while (!check() && System.nanoTime() < until) { Thread.sleep(15); shadowOf(Looper.getMainLooper()).idle() }
        assertTrue("Timed out waiting for UI", check())
    }
    private fun cache(path: String, raw: String) {
        val f = Abs::class.java.getDeclaredMethod("cacheFile", String::class.java).apply { isAccessible = true }.invoke(Abs, path) as File
        f.parentFile!!.mkdirs(); f.writeText(raw)
    }
    private fun fixture(run: (Main, HttpServer) -> Unit) {
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val executor = Executors.newCachedThreadPool()
        server.executor = executor
        Abs.offline = false
        Abs.now = null
        (Abs::class.java.getDeclaredField("cacheDir").apply { isAccessible = true }.get(Abs) as File).listFiles()?.forEach { it.delete() }
        Abs.p.edit().clear().putString("server", "http://127.0.0.1:" + server.address.port).putString("me", "fixture")
            .putString("acct:fixture", """{"a":"fixture","r":""}""").putString("favq", """{}""").commit()
        try { run(a, server) } finally {
            server.stop(0); executor.shutdownNow(); Abs.p.edit().clear().commit(); Abs.offline = false
            Dl.jobs.clear()
            (Abs::class.java.getDeclaredField("cacheDir").apply { isAccessible = true }.get(Abs) as File).listFiles()?.forEach { it.delete() }
            controller.destroy()
        }
    }
    private fun HttpServer.route(path: String, code: Int = 200, body: () -> String) = createContext(path) { x ->
        val bytes = body().toByteArray()
        runCatching { x.sendResponseHeaders(code, bytes.size.toLong()); x.responseBody.use { it.write(bytes) } }
    }
    private val me = """{"mediaProgress":[],"bookmarks":[]}"""
    private val libs = """{"libraries":[{"id":"books","name":"Books","mediaType":"book"}]}"""
    private fun book(id: String) = """{"id":"$id","mediaType":"book","media":{"metadata":{"title":"Title $id"},"tracks":[]}}"""

    @Test fun coldLibraryShowsLoadingThenEmptyAndRetryIsSingleFlight() = fixture { a, s ->
        val release = CountDownLatch(1); val requested = CountDownLatch(1); val calls = AtomicInteger()
        s.route("/api/libraries/books/items", 503) { calls.incrementAndGet(); requested.countDown(); release.await(5, TimeUnit.SECONDS); """{}""" }
        s.route("/api/libraries") { libs }; s.route("/api/me") { me }; s.start()
        Abs.p.edit().putString("lib", "books").commit()
        a.call("tab", 1)
        assertTrue(a.has("Loading titles…")); assertFalse(a.has("No titles in this library."))
        assertTrue(requested.await(5, TimeUnit.SECONDS)); release.countDown()
        await { a.has("Couldn't load titles.") }
        s.removeContext("/api/libraries/books/items")
        val retryRelease = CountDownLatch(1)
        s.route("/api/libraries/books/items") { calls.incrementAndGet(); retryRelease.await(5, TimeUnit.SECONDS); """{"results":[]}""" }
        val retry = a.button("Retry"); retry.performClick(); retry.performClick()
        assertTrue(a.has("Loading titles…")); retryRelease.countDown()
        await { a.has("No titles in this library.") }
        assertFalse(a.has("Loading titles…")); assertEquals(2, calls.get())
    }

    @Test fun cachedLibraryRefreshFailureRetainsSearchAndBackThenRetriesWithoutReplacingView() = fixture { a, s ->
        cache("/api/libraries/books/items?minified=1&sort=media.metadata.title", org.json.JSONObject().put("results", org.json.JSONArray().put(org.json.JSONObject(book("cached")))).toString())
        val release = CountDownLatch(1)
        s.route("/api/libraries/books/items", 500) { release.await(5, TimeUnit.SECONDS); """{}""" }
        s.route("/api/libraries") { libs }; s.route("/api/me") { me }; s.route("/api/items/detail", 500) { """{}""" }; s.start()
        Abs.p.edit().putString("lib", "books").commit()
        a.call("tab", 1); val page = a.content().getChildAt(0)
        assertTrue(a.has("Updating titles…"))
        val search = views(page).filterIsInstance<TextInputEditText>().single(); search.setText("cached")
        a.call("push", { a.call("item", "detail") }); release.countDown()
        a.onBackPressedDispatcher.onBackPressed(); layout(a.content())
        await { a.has("Couldn't update titles. Showing saved content.") }
        assertSame(page, a.content().getChildAt(0)); assertEquals("cached", search.text.toString())
        assertEquals(1, views(page).filterIsInstance<RecyclerView>().single().adapter!!.itemCount)
        s.removeContext("/api/libraries/books/items"); s.route("/api/libraries/books/items") { """{"results":[]}""" }
        a.button("Retry").performClick(); await { a.has("No matching titles.") }
        assertSame(page, a.content().getChildAt(0)); assertEquals("cached", search.text.toString())
    }

    @Test fun switchedLibraryAndPoppedDetailIgnoreLateSuccessAndFailure() = fixture { a, s ->
        val oldRelease = CountDownLatch(1); val oldRequested = CountDownLatch(1)
        s.route("/api/libraries/books/items") { oldRequested.countDown(); oldRelease.await(5, TimeUnit.SECONDS); org.json.JSONObject().put("results", org.json.JSONArray().put(org.json.JSONObject(book("old")))).toString() }
        s.route("/api/libraries/new/items") { """{"results":[]}""" }
        s.route("/api/libraries") { libs }; s.route("/api/me") { me }; s.start()
        Abs.p.edit().putString("lib", "books").commit(); a.call("tab", 1)
        assertTrue(oldRequested.await(5, TimeUnit.SECONDS))
        Abs.p.edit().putString("lib", "new").commit(); a.call("library")
        val page = a.content().getChildAt(0); await { a.has("No titles in this library.") }
        oldRelease.countDown(); await { Abs.cached("/api/libraries/books/items?minified=1&sort=media.metadata.title") != null }
        assertSame(page, a.content().getChildAt(0)); assertEquals(0, views(page).filterIsInstance<RecyclerView>().single().adapter!!.itemCount)
        val detailRelease = CountDownLatch(1); val detailRequested = CountDownLatch(1)
        val detailDone = CountDownLatch(1)
        s.route("/api/items/late", 401) { detailRequested.countDown(); detailRelease.await(5, TimeUnit.SECONDS); detailDone.countDown(); """{}""" }
        a.call("push", { a.call("item", "late") }); assertTrue(a.has("Loading title…"))
        assertTrue(detailRequested.await(5, TimeUnit.SECONDS)); a.onBackPressedDispatcher.onBackPressed(); detailRelease.countDown()
        await { Abs.cached("/api/libraries/new/items?minified=1&sort=media.metadata.title") != null }
        assertTrue(detailDone.await(5, TimeUnit.SECONDS))
        Thread.sleep(50); shadowOf(Looper.getMainLooper()).idle()
        assertSame(page, a.content().getChildAt(0)); assertFalse(a.has("Sign in"))
    }

    @Test fun homeAndSeriesNeverClaimEmptyWhilePending() = fixture { a, s ->
        val release = CountDownLatch(1)
        s.route("/api/me/items-in-progress") { release.await(5, TimeUnit.SECONDS); """{"libraryItems":[]}""" }
        s.route("/api/me") { me }; s.route("/api/libraries") { libs }
        val seriesRelease = CountDownLatch(1)
        s.route("/api/libraries/books/series") { seriesRelease.await(5, TimeUnit.SECONDS); """{"results":[]}""" }; s.start()
        a.call("tab", 0); assertTrue(a.has("Loading continue listening…")); assertFalse(a.has("Nothing to continue listening to."))
        release.countDown(); await { a.has("Nothing to continue listening to.") }
        a.call("tab", 2); assertFalse(a.has("No series on the server yet."))
        await { a.has("Loading Books series…") }; assertFalse(a.has("No series on the server yet."))
        seriesRelease.countDown(); await { a.has("No series on the server yet.") }
    }

    @Test fun detailMalformedResponseIsRetryableAndOfflineCacheIsNotBlank() = fixture { a, s ->
        s.route("/api/items/bad") { "not-json" }; s.start()
        a.call("push", { a.call("item", "bad") }); assertTrue(a.has("Loading title…"))
        await { a.has("Couldn't load title.") }
        s.removeContext("/api/items/bad"); s.route("/api/items/bad") { book("bad") }
        a.button("Retry").performClick(); await { !a.has("Loading title…") && !a.has("Couldn't load title.") }
        layout(a.content()); assertTrue(a.has("Title bad"))
        Abs.p.edit().putString("server", "http://127.0.0.1:1").commit()
        a.call("item", "bad"); assertTrue(a.has("Updating title…"))
        await { a.has("Offline · showing saved title") }; layout(a.content()); assertTrue(a.has("Title bad"))
    }

    @Test fun playbackRepeatedTapIsSingleFlightAndBackCancelsCompletion() = fixture { a, s ->
        val release = CountDownLatch(1); val calls = AtomicInteger()
        s.route("/api/me/progress/audio") { calls.incrementAndGet(); release.await(5, TimeUnit.SECONDS); """{"currentTime":12}""" }; s.start()
        a.call("push", { a.call("shelf", "Audio", emptyList<Card>(), 1f) })
        val n = Now("audio", null, "Audio", "", listOf(Track("1", ".mp3", 10, 60.0, 0.0)))
        repeat(3) { a.call("play", n) }; assertTrue(a.has("Loading audio…"))
        await { calls.get() == 1 }; a.onBackPressedDispatcher.onBackPressed(); release.countDown()
        await { Main::class.java.getDeclaredField("pendingPlay").apply { isAccessible = true }.get(a) == null }
        assertFalse(a.has("Loading audio…")); assertNull(Abs.now); assertEquals(1, calls.get())
    }

    @Test fun downloadScreenShowsQueuedWaitingErrorRetryAndCancel() = fixture { a, s ->
        s.start()
        val n = Now("download", null, "Download", "", listOf(Track("1", ".mp3", 100, 60.0, 0.0)))
        val first = Dl.Job(n).apply { waiting = true }
        Dl.jobs += first; Dl.jobs += Dl.Job(Now("queued", null, "Queued title", "", n.tracks))
        a.call("push", { a.call("downloads") }); assertTrue(a.has("Waiting for connection")); assertTrue(a.has("Queued"))
        first.error = "Couldn't download (HTTP 404)"; a.call("downloads")
        assertTrue(a.has("Couldn't download (HTTP 404)")); a.button("Retry").performClick(); assertNull(first.error)
        views(a.content()).first { it.contentDescription == "Cancel download of Download" }.performClick()
        (org.robolectric.shadows.ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog)
            .getButton(android.content.DialogInterface.BUTTON_POSITIVE).performClick()
        shadowOf(Looper.getMainLooper()).idle()
        assertNull(Dl.job(n.key)); assertEquals(1, Dl.jobs.size)
    }

    @Test fun loginAndLinkedAccountKeepControlsPendingAndAllowFailureRetry() = fixture { a, s ->
        val release = CountDownLatch(1); val linkedRelease = CountDownLatch(1); val calls = AtomicInteger()
        s.route("/login", 401) { if (calls.incrementAndGet() == 1) release.await(5, TimeUnit.SECONDS) else linkedRelease.await(5, TimeUnit.SECONDS); "{}" }; s.start()
        a.call("login")
        val fields = views(a.content()).filterIsInstance<TextInputEditText>()
        fields[0].setText(Abs.server); fields[1].setText("fixture"); fields[2].setText("fixture")
        val go = a.button("Sign in"); go.performClick(); go.performClick()
        assertTrue(a.has("Signing in…")); assertFalse(go.isEnabled)
        await { calls.get() == 1 }; release.countDown(); await { go.isEnabled }
        assertTrue(a.has("Sign in")); assertEquals(1, calls.get())
        a.call("addAccount", {})
        val dialog = org.robolectric.shadows.ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog
        val link = dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE)
        link.performClick(); link.performClick(); assertEquals("Linking…", link.text.toString()); assertFalse(link.isEnabled)
        linkedRelease.countDown(); await { link.isEnabled }; assertTrue(dialog.isShowing)
        assertTrue(views(dialog.window!!.decorView).filterIsInstance<TextView>().any { it.text == "Wrong username or password" })
        assertEquals(2, calls.get()); dialog.dismiss()
    }

    @Test fun favoritesMetadataLoadingStaysWithHiddenOwnerAndRetries() = fixture { a, s ->
        s.route("/api/me") { org.json.JSONObject(me).put("bookmarks", org.json.JSONArray().put(org.json.JSONObject().put("libraryItemId", "missing").put("title", "♥ Favorite"))).toString() }
        val release = CountDownLatch(1); val requested = CountDownLatch(1)
        s.route("/api/items/missing", 500) { requested.countDown(); release.await(5, TimeUnit.SECONDS); "{}" }; s.start()
        a.call("tab", 3); assertTrue(a.has("Loading favorites…")); assertFalse(a.has("Tap ♡ on a book or podcast to keep it here."))
        await { a.has("Loading favorite details…") }; assertTrue(requested.await(5, TimeUnit.SECONDS))
        val page = a.content().getChildAt(0)
        a.call("push", { a.call("shelf", "Details", emptyList<Card>(), 1f) }); release.countDown()
        a.onBackPressedDispatcher.onBackPressed(); await { a.has("Couldn't load favorite details.") }
        s.removeContext("/api/items/missing"); s.route("/api/items/missing") { book("missing") }
        a.button("Retry").performClick(); await { Abs.favs().any { it.title == "Title missing" } }
        assertSame(page, a.content().getChildAt(0)); layout(a.content()); assertTrue(a.has("Title missing"))
    }

    @Test fun realCoverViewsDeduplicateAndRejectLateReboundArtwork() = fixture { a, s ->
        val release = CountDownLatch(1); val calls = AtomicInteger()
        val bytes = java.io.ByteArrayOutputStream().also { out ->
            android.graphics.Bitmap.createBitmap(2, 2, android.graphics.Bitmap.Config.ARGB_8888).compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
        }.toByteArray()
        s.createContext("/api/items/cover/cover") { x ->
            calls.incrementAndGet(); release.await(5, TimeUnit.SECONDS)
            runCatching { x.sendResponseHeaders(200, bytes.size.toLong()); x.responseBody.use { it.write(bytes) } }
        }
        s.route("/api/items/no-cover/cover", 404) { "{}" }; s.start()
        a.call("push", { a.call("shelf", "Covers", emptyList<Card>(), 1f) })
        val first = Cover(a); val second = Cover(a)
        a.content().addView(first); a.content().addView(second)
        Covers.load(first, "cover"); Covers.load(second, "cover")
        assertEquals("Loading cover", first.contentDescription); assertNotNull(first.drawable)
        await { calls.get() == 1 }; Covers.load(first, "no-cover"); release.countDown()
        await { second.contentDescription == "Cover" && first.contentDescription == "No cover available" }
        assertEquals("no-cover", first.tag); assertEquals(1, calls.get())
    }

    @Test fun disconnectedDetailHasExplicitRetryAndNeverAnEmptySuccess() = fixture { a, s ->
        s.start(); Abs.p.edit().putString("server", "http://127.0.0.1:1").commit()
        a.call("push", { a.call("item", "uncached") })
        assertTrue(a.has("Loading title…")); await { a.has("Offline · title unavailable") }
        assertTrue(a.button("Retry").isEnabled); assertFalse(a.has("No audio available."))
    }

    @Test fun emptyLibrariesAndFavoriteMembershipHaveTerminalEmptyStates() = fixture { a, s ->
        s.route("/api/libraries") { org.json.JSONObject().put("libraries", org.json.JSONArray()).toString() }
        s.route("/api/me") { me }; s.start()
        a.call("tab", 1); assertTrue(a.has("Loading libraries…")); await { a.has("No libraries available.") }
        a.call("tab", 3); await { a.has("Tap ♡ on a book or podcast to keep it here.") }
        assertFalse(a.has("Loading favorites…"))
    }

    @Test fun newerPlaybackSelectionOwnsLoadingAndOldCompletionCannotReplaceIt() = fixture { a, s ->
        val oldRelease = CountDownLatch(1); val newRelease = CountDownLatch(1)
        val oldCalls = AtomicInteger(); val newCalls = AtomicInteger()
        s.route("/api/me/progress/old") { oldCalls.incrementAndGet(); oldRelease.await(5, TimeUnit.SECONDS); "{}" }
        s.route("/api/me/progress/new") { newCalls.incrementAndGet(); newRelease.await(5, TimeUnit.SECONDS); "{}" }; s.start()
        a.call("push", { a.call("shelf", "Play", emptyList<Card>(), 1f) })
        fun now(id: String) = Now(id, null, id, "", listOf(Track("audio", ".mp3", 10, 60.0, 0.0)))
        a.call("play", now("old")); await { oldCalls.get() == 1 }
        a.call("play", now("new")); a.call("play", now("new")); await { newCalls.get() == 1 }
        oldRelease.countDown()
        val pending = Main::class.java.getDeclaredField("pendingPlay").apply { isAccessible = true }
        await { views(a.content()).filterIsInstance<TextView>().count { it.text == "Loading audio…" && visible(it) } == 1 }
        assertEquals("new", pending.get(a)); assertNull(Abs.now)
        newRelease.countDown(); await { a.has("Couldn't load audio.") }
        assertNull(pending.get(a)); assertNull(Abs.now); assertEquals(1, newCalls.get())
    }

    @Test fun wrongSchemaRefreshKeepsExpandedSnapshotForOfflineReopen() = fixture { a, s ->
        val path = "/api/items/saved?expanded=1"
        val saved = book("saved")
        cache(path, saved)
        s.route("/api/items/saved") { "{}" }; s.start()
        a.call("push", { a.call("item", "saved") })
        assertTrue(a.has("Updating title…"))
        await { a.has("Couldn't update title. Showing saved content.") }
        layout(a.content()); assertTrue(a.has("Title saved")); assertEquals(saved, Abs.cached(path))
        a.onBackPressedDispatcher.onBackPressed()
        s.stop(0)
        a.call("push", { a.call("item", "saved") })
        await { a.has("Offline · showing saved title") }
        layout(a.content()); assertTrue(a.has("Title saved")); assertEquals(saved, Abs.cached(path))
    }

    @Test fun blankArtworkRebindInvalidatesDelayedResultForIdAndServer() = fixture { a, s ->
        val release = CountDownLatch(1); val requested = CountDownLatch(1)
        val bytes = java.io.ByteArrayOutputStream().also { out ->
            android.graphics.Bitmap.createBitmap(2, 2, android.graphics.Bitmap.Config.ARGB_8888)
                .compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
        }.toByteArray()
        s.createContext("/api/items/blank-rebind/cover") { x ->
            requested.countDown(); release.await(5, TimeUnit.SECONDS)
            runCatching { x.sendResponseHeaders(200, bytes.size.toLong()); x.responseBody.use { it.write(bytes) } }
        }; s.start()
        a.call("push", { a.call("shelf", "Covers", emptyList<Card>(), 1f) })
        val blankId = Cover(a); val blankServer = Cover(a); val witness = Cover(a)
        listOf(blankId, blankServer, witness).forEach { a.content().addView(it); Covers.load(it, "blank-rebind") }
        assertTrue(requested.await(5, TimeUnit.SECONDS))
        val idToken = blankId.getTag(R.id.cover_request); val serverToken = blankServer.getTag(R.id.cover_request)
        Covers.load(blankId, "")
        val server = Abs.server
        Abs.p.edit().putString("server", "").commit(); Covers.load(blankServer, "blank-rebind")
        Abs.p.edit().putString("server", server).commit()
        assertNotSame(idToken, blankId.getTag(R.id.cover_request)); assertNotSame(serverToken, blankServer.getTag(R.id.cover_request))
        val placeholder = blankId.drawable; val serverPlaceholder = blankServer.drawable
        release.countDown(); await { witness.contentDescription == "Cover" }
        assertEquals("", blankId.tag); assertEquals("No cover available", blankId.contentDescription)
        assertEquals("No cover available", blankServer.contentDescription)
        assertSame(placeholder, blankId.drawable); assertSame(serverPlaceholder, blankServer.drawable)
    }

    @Test fun actualDownloaderRetains404ButRunsNextJobAndRetriesFailedJob() = fixture { a, s ->
        val calls = java.util.Collections.synchronizedList(mutableListOf<String>())
        val secondRelease = CountDownLatch(1)
        s.route("/api/items/failed-job/file/audio/download", 404) { calls += "failed"; "missing" }
        s.route("/api/items/next-job/file/audio/download") { calls += "next"; secondRelease.await(5, TimeUnit.SECONDS); "audio" }; s.start()
        fun now(id: String) = Now(id, null, id, "", listOf(Track("audio", ".mp3", 5, 60.0, 0.0)))
        val failed = now("failed-job"); val next = now("next-job")
        listOf(failed, next).forEach { Abs.remove(it.tracks.map { t -> Abs.file(it.item, t) }); Dl.add(a, it) }
        val service = Robolectric.buildService(DlService::class.java).create()
        try {
            service.get().onStartCommand(null, 0, 1)
            await { calls.size == 2 }
            assertEquals(listOf("failed", "next"), calls.toList())
            val job = Dl.job(failed.key)!!
            assertTrue(job.error!!.contains("404")); assertEquals(next.key, Dl.next!!.n.key)
            a.call("push", { a.call("downloads") }); assertTrue(a.has(job.error!!))
            secondRelease.countDown(); await { Dl.idle && Dl.job(next.key) == null }
            assertSame(job, Dl.job(failed.key)); assertEquals("audio", Abs.file(next.item, next.tracks.single()).readText())
            s.removeContext("/api/items/failed-job/file/audio/download")
            s.route("/api/items/failed-job/file/audio/download") { calls += "retry"; "audio" }
            a.button("Retry").performClick()
            service.get().onStartCommand(null, 0, 2)
            await { Dl.idle && Dl.jobs.isEmpty() }
            assertEquals(listOf("failed", "next", "retry"), calls.toList())
            assertEquals("audio", Abs.file(failed.item, failed.tracks.single()).readText())
        } finally {
            secondRelease.countDown(); Dl.clear(); await { Dl.idle }; service.destroy()
            listOf(failed, next).forEach { Abs.remove(it.tracks.map { t -> Abs.file(it.item, t) }) }
        }
    }

    @Test fun everyCachedRouteRejectsWrongSchemaWithoutReplacingItsSnapshot() = fixture { _, s ->
        val routes = listOf("/api/me", "/api/me/items-in-progress?limit=20", "/api/libraries",
            "/api/libraries/books/items?minified=1", "/api/libraries/books/series?limit=1000",
            "/api/items/title", "/api/items/title?expanded=1")
        s.route("/") { "{}" }; s.start()
        routes.forEach { path ->
            cache(path, "preserved fixture")
            assertTrue(path, runCatching { Abs.get(path) }.isFailure)
            assertEquals(path, "preserved fixture", Abs.cached(path))
        }
    }
    private fun audioBook(id: String) = org.json.JSONObject(book(id)).apply {
        getJSONObject("media").put("tracks", org.json.JSONArray().put(org.json.JSONObject()
            .put("ino", "audio").put("duration", 60).put("metadata", org.json.JSONObject().put("ext", ".mp3").put("size", 7))))
    }.toString()

    @Test fun mountedLibraryReconnectAndOfflineBackRetainQueryAnchorAndRefreshMembership() = fixture { a, s ->
        val ids = (0 until 160).map { "reconnect%03d".format(it) }
        ids.forEach { id ->
            cache("/api/items/$id?expanded=1", audioBook(id))
            File(Abs.dir, "$id/audio.mp3").apply { parentFile!!.mkdirs(); writeText("fixture") }
        }
        Abs.dlChanged()
        val librariesRelease = CountDownLatch(1)
        try {
            val pingCalls = AtomicInteger(); val libCalls = AtomicInteger(); val titleCalls = AtomicInteger(); val progressCalls = AtomicInteger()
            val pingRelease = CountDownLatch(1); val titlesRelease = CountDownLatch(1)
            s.route("/ping") { pingCalls.incrementAndGet(); pingRelease.await(5, TimeUnit.SECONDS); "{}" }
            s.route("/api/libraries") { libCalls.incrementAndGet(); librariesRelease.await(); libs }
            s.route("/api/libraries/books/items") {
                titleCalls.incrementAndGet(); titlesRelease.await(5, TimeUnit.SECONDS)
                org.json.JSONObject().put("results", org.json.JSONArray((ids + "reconnectRemote").map { org.json.JSONObject(book(it)) })).toString()
            }
            s.route("/api/me") { progressCalls.incrementAndGet(); me }
            ids.forEach { id ->
                s.route("/api/items/$id") { audioBook(id) }
                s.route("/api/items/$id/cover", 404) { "{}" }
            }
            s.start(); Abs.p.edit().putString("lib", "books").commit(); Abs.offline = true
            a.call("tab", 1); a.connectivityTick()
            val page = a.content().getChildAt(0)
            val search = views(page).filterIsInstance<TextInputEditText>().single()
            search.setText("Title reconnect")
            val grid = views(page).filterIsInstance<RecyclerView>().single()
            val lm = grid.layoutManager as androidx.recyclerview.widget.GridLayoutManager
            layout(a.content()); lm.scrollToPositionWithOffset(80, -31); layout(a.content())
            fun anchor() = lm.findViewByPosition(lm.findFirstVisibleItemPosition())!!
            fun key() = anchor().tag.let { tag -> tag.javaClass.getDeclaredField("key").apply { isAccessible = true }.get(tag) as String }
            val key = key(); val offset = lm.getDecoratedTop(anchor()) - grid.paddingTop
            assertEquals(160, grid.adapter!!.itemCount); assertEquals(0, titleCalls.get())
            val banner = Main::class.java.getDeclaredField("banner").apply { isAccessible = true }.get(a) as ViewGroup
            val retry = views(banner).filterIsInstance<MaterialButton>().single()
            retry.performClick(); retry.performClick(); await { pingCalls.get() == 1 }
            assertFalse(retry.isEnabled); assertEquals("Connecting…", retry.text.toString())
            pingRelease.countDown(); await { titleCalls.get() == 1 && libCalls.get() == 1 && progressCalls.get() == 1 }
            titlesRelease.countDown(); await { grid.adapter!!.itemCount == 161 }
            // Titles can finish before library discovery. Network entry counts are not UI delivery.
            assertTrue(views(page).filterIsInstance<com.google.android.material.chip.Chip>().isEmpty())
            librariesRelease.countDown()
            await {
                views(page).filterIsInstance<com.google.android.material.chip.Chip>().singleOrNull()?.let {
                    it.isChecked && visible(it)
                } == true && !a.has("Updating progress…") && !a.has("Loading progress…")
            }
            layout(a.content())
            assertSame(page, a.content().getChildAt(0)); assertSame(lm, grid.layoutManager)
            assertEquals("Title reconnect", search.text.toString()); assertEquals(key, key())
            assertEquals(offset, lm.getDecoratedTop(anchor()) - grid.paddingTop)
            assertFalse(banner.visibility == View.VISIBLE)
            assertTrue(views(page).filterIsInstance<com.google.android.material.chip.Chip>().single().isChecked)
            assertTrue(a.has("Library"))
            // Actual grid click opens the real title detail, not a substitute shelf.
            anchor().performClick(); await { !a.has("Loading title…") && !a.has("Updating title…") }
            Abs.offline = true; a.connectivityTick()
            a.onBackPressedDispatcher.onBackPressed(); layout(a.content())
            assertSame(page, a.content().getChildAt(0)); assertEquals(160, grid.adapter!!.itemCount)
            assertEquals("Title reconnect", search.text.toString()); assertEquals(key, key())
            assertEquals(offset, lm.getDecoratedTop(anchor()) - grid.paddingTop)
            assertTrue(a.has("Downloaded")); assertFalse(visible(views(page).filterIsInstance<com.google.android.material.chip.Chip>().single()))
            // Visible connectivity transitions also recompute membership without navigation.
            Abs.offline = false; a.connectivityTick()
            await { titleCalls.get() == 2 && libCalls.get() == 2 && progressCalls.get() == 2 }
            await { !a.has("Updating titles…") && !a.has("Updating libraries…") && !a.has("Updating progress…") }
            layout(a.content())
            assertEquals(161, grid.adapter!!.itemCount)
            Abs.offline = true; a.connectivityTick(); layout(a.content())
            assertEquals(160, grid.adapter!!.itemCount); assertEquals(key, key())
            assertEquals(offset, lm.getDecoratedTop(anchor()) - grid.paddingTop)
            assertEquals(1, pingCalls.get())
        } finally {
            librariesRelease.countDown() // Also release on failed assertions before fixture server/executor teardown.
            ids.forEach { File(Abs.dir, it).deleteRecursively() }; Abs.dlChanged()
        }
    }

    @Test fun homePlayRefetchesPoisonedExpandedCacheAndRetryReachesProgress() = fixture { a, s ->
        val itemCalls = AtomicInteger(); val progressCalls = AtomicInteger()
        val response = java.util.concurrent.atomic.AtomicReference("{}")
        s.route("/api/me") { me }
        s.route("/api/me/items-in-progress") { org.json.JSONObject().put("libraryItems", org.json.JSONArray().put(org.json.JSONObject(book("poison")))).toString() }
        s.route("/api/items/poison") { itemCalls.incrementAndGet(); response.get() }
        s.route("/api/items/poison/cover", 404) { "{}" }
        s.route("/api/me/progress/poison") { progressCalls.incrementAndGet(); """{"currentTime":0}""" }
        s.start()
        for ((index, poisoned) in listOf("{}", "not-json", book("poison")).withIndex()) {
            cache("/api/items/poison?expanded=1", poisoned)
            response.set("{}")
            a.call("tab", 0)
            val page = a.content().getChildAt(0)
            val list = views(page).filterIsInstance<RecyclerView>().single()
            await { list.adapter!!.itemCount == 1 }; layout(a.content())
            val tile = (list.layoutManager as androidx.recyclerview.widget.LinearLayoutManager).findViewByPosition(0)!!
            tile.performClick(); assertTrue(a.has("Loading audio…"))
            await { a.has("Couldn't load audio.") }
            assertEquals(index * 2 + 1, itemCalls.get()); assertEquals(index, progressCalls.get())
            assertEquals(poisoned, Abs.cached("/api/items/poison?expanded=1"))
            response.set(audioBook("poison"))
            val retry = a.button("Retry"); retry.performClick(); retry.performClick()
            await { progressCalls.get() == index + 1 && a.has("Couldn't load audio.") }
            // No media controller is attached in this fixture. Reaching positions proves metadata
            // recovery; terminal Player-not-ready remains retryable rather than claiming playback.
            assertEquals(index * 2 + 2, itemCalls.get())
            assertEquals(audioBook("poison"), Abs.cached("/api/items/poison?expanded=1"))
            assertSame(page, a.content().getChildAt(0))
        }
    }

}
