package com.borodutch.absplus

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleRegistry
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.os.Looper
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.robolectric.Shadows.shadowOf
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.textfield.TextInputEditText
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Real Activity navigation and RecyclerView layout; no server, account or playback. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NavigationTest {
    private fun Main.call(name: String, vararg args: Any) {
        val m = Main::class.java.declaredMethods.single { it.name == name }
        m.isAccessible = true
        m.invoke(this, *args)
    }
    private fun Main.content() = Main::class.java.getDeclaredField("content").let {
        it.isAccessible = true; it.get(this) as FrameLayout
    }
    private fun layout(v: View) {
        v.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1800, View.MeasureSpec.EXACTLY))
        v.layout(0, 0, 1080, 1800)
    }
    private fun views(v: View): List<View> = listOf(v) + if (v is ViewGroup) (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()

    @Test fun deepShelfReturnsToSameItemAndOffsetThroughBothBackPaths() {
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        val cards = (0..499).map { Card("id$it", "Title $it", "Author") }
        a.call("push", { a.call("shelf", "Large shelf", cards, 1f) })
        val page = a.content().getChildAt(0)
        layout(a.content())
        val grid = views(page).filterIsInstance<RecyclerView>().single()
        val lm = grid.layoutManager as GridLayoutManager
        lm.scrollToPositionWithOffset(320, -37)
        layout(a.content())
        val position = lm.findFirstVisibleItemPosition()
        val offset = lm.findViewByPosition(position)!!.top
        assertTrue(position >= 300)
        repeat(3) { round ->
            // The pushed page uses the same push()/begin()/show() path as title details,
            // without asking a real server for an expanded item.
            a.call("push", { a.call("shelf", "Details", cards.take(1), 1f) })
            layout(a.content())
            if (round % 2 == 0) a.onBackPressedDispatcher.onBackPressed()
            else views(a.content()).single { it.contentDescription == "Back" }.performClick()
            layout(a.content())
            assertSame(page, a.content().getChildAt(0))
            assertSame(lm, grid.layoutManager)
            assertEquals(position, lm.findFirstVisibleItemPosition())
            assertEquals(offset, lm.findViewByPosition(position)!!.top)
        }
        controller.destroy()
    }

    @Test fun pendingLayoutAndSearchSurviveButExplicitTabDoesNot() {
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        Abs.offline = true // exercise the real library builder without network
        a.call("tab", 1)
        val page = a.content().getChildAt(0)
        val search = views(page).filterIsInstance<TextInputEditText>().single()
        search.setText("a title query")
        a.call("push", { a.call("shelf", "Details", emptyList<Card>(), 1f) })
        // First layout only happens after returning (e.g. an asynchronous render).
        a.onBackPressedDispatcher.onBackPressed()
        layout(a.content())
        assertSame(page, a.content().getChildAt(0))
        assertEquals("a title query", search.text.toString())
        a.call("tab", 1)
        assertNotSame(page, a.content().getChildAt(0))
        assertEquals("", views(a.content()).filterIsInstance<TextInputEditText>().single().text.toString())
        Abs.offline = false
        controller.destroy()
    }

    @Test fun delayedLibraryResultsRemainAttachedToTheHiddenList() {
        val response = CountDownLatch(1)
        val requested = CountDownLatch(1)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val result = JSONObject().put("results", JSONArray((0..499).map {
            JSONObject().put("id", "book$it").put("media", JSONObject().put("metadata", JSONObject().put("title", "Title $it")))
        })).toString()
        server.createContext("/") { x ->
            val body = when (x.requestURI.path) {
                "/api/libraries/books/items" -> { requested.countDown(); response.await(5, TimeUnit.SECONDS); result }
                "/api/libraries" -> "{\"libraries\":[{\"id\":\"books\",\"name\":\"Books\"}]}"
                "/api/me" -> "{\"mediaProgress\":[],\"bookmarks\":[]}"
                else -> "{}"
            }
            val bytes = body.toByteArray()
            x.sendResponseHeaders(200, bytes.size.toLong())
            x.responseBody.use { it.write(bytes) }
        }
        server.start()
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        try {
            Abs.offline = false
            Abs.p.edit().putString("server", "http://127.0.0.1:${server.address.port}")
                .putString("lib", "books").putString("me", "fixture")
                .putString("acct:fixture", "{\"a\":\"fixture\",\"r\":\"\"}").commit()
            a.call("tab", 1)
            val page = a.content().getChildAt(0)
            val grid = views(page).filterIsInstance<RecyclerView>().single()
            assertTrue(requested.await(5, TimeUnit.SECONDS))
            a.call("push", { a.call("shelf", "Details", emptyList<Card>(), 1f) })
            response.countDown()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (grid.adapter!!.itemCount < 500 && System.nanoTime() < deadline) {
                Thread.sleep(20)
                shadowOf(Looper.getMainLooper()).idle()
            }
            assertEquals(500, grid.adapter!!.itemCount)
            a.onBackPressedDispatcher.onBackPressed()
            layout(a.content())
            assertSame(page, a.content().getChildAt(0))
            val search = views(page).filterIsInstance<TextInputEditText>().single()
            search.setText("Title 3")
            layout(a.content())
            assertEquals(111, grid.adapter!!.itemCount)
            val lm = grid.layoutManager as GridLayoutManager
            lm.scrollToPositionWithOffset(80, -29)
            layout(a.content())
            val first = lm.findFirstVisibleItemPosition()
            val offset = lm.findViewByPosition(first)!!.top
            a.call("push", { a.call("shelf", "Details", emptyList<Card>(), 1f) })
            a.onBackPressedDispatcher.onBackPressed()
            layout(a.content())
            assertSame(page, a.content().getChildAt(0))
            assertEquals("Title 3", search.text.toString())
            assertEquals(111, grid.adapter!!.itemCount)
            assertEquals(first, lm.findFirstVisibleItemPosition())
            assertEquals(offset, lm.findViewByPosition(first)!!.top)
        } finally {
            response.countDown()
            server.stop(0)
            Abs.p.edit().remove("me").commit()
            controller.destroy()
        }
    }

    @Test fun libraryChangeInvalidatesRetainedPage() {
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        Abs.offline = true
        a.call("tab", 1)
        val page = a.content().getChildAt(0)
        a.call("push", { a.call("shelf", "Details", emptyList<Card>(), 1f) })
        Abs.p.edit().putString("lib", "another-library").commit()
        a.onBackPressedDispatcher.onBackPressed()
        assertNotSame(page, a.content().getChildAt(0))
        Abs.offline = false
        controller.destroy()
    }

    private fun title(lm: GridLayoutManager, at: Int) = views(lm.findViewByPosition(at)!!)
        .filterIsInstance<android.widget.TextView>().first { it.text.startsWith("Title") }.text.toString()

    @Test fun offlineDeletesRefreshOnReturnAndDownloadChangeWithoutLosingAnchor() {
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        Abs.offline = true
        repeat(200) { i ->
            val id = "download$i"
            java.io.File(Abs.mediaDir, "audio/$id").mkdirs()
            java.io.File(Abs.mediaDir, "audio/$id/audio.mp3").writeText("fixture")
            val cache = Abs::class.java.getDeclaredMethod("cacheFile", String::class.java).apply { isAccessible = true }
                .invoke(Abs, "/api/items/$id?expanded=1") as java.io.File
            cache.parentFile!!.mkdirs()
            cache.writeText(JSONObject().put("id", id)
                .put("media", JSONObject().put("tracks", JSONArray().put(JSONObject().put("ino", "audio").put("duration", 60)
                    .put("metadata", JSONObject().put("ext", ".mp3").put("size", 7))))
                    .put("metadata", JSONObject().put("title", "Title $i"))).toString())
        }
        Abs.dlChanged()
        a.call("tab", 1)
        val page = a.content().getChildAt(0)
        views(page).filterIsInstance<TextInputEditText>().single().setText("Title ")
        val grid = views(page).filterIsInstance<RecyclerView>().single()
        val lm = grid.layoutManager as GridLayoutManager
        layout(a.content())
        lm.scrollToPositionWithOffset(100, -29)
        layout(a.content())
        val first = lm.findFirstVisibleItemPosition()
        val name = title(lm, first)
        val y = lm.findViewByPosition(first)!!.top
        val originals = Abs.downloads().filter { it.name.startsWith("download") }
        a.call("push", { a.call("settings") })
        a.call("push", { a.call("downloads") })
        originals.take(4).forEach(Abs::removeAll)
        a.onBackPressedDispatcher.onBackPressed()
        a.onBackPressedDispatcher.onBackPressed()
        layout(a.content())
        assertSame(page, a.content().getChildAt(0))
        assertEquals(196, grid.adapter!!.itemCount)
        assertEquals(name, title(lm, lm.findFirstVisibleItemPosition()))
        assertEquals(y, lm.findViewByPosition(lm.findFirstVisibleItemPosition())!!.top)
        originals.drop(4).take(4).forEach(Abs::removeAll)
        val onDl = Main::class.java.getDeclaredField("onDl").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        (onDl.get(a) as () -> Unit).invoke()
        layout(a.content())
        assertEquals(192, grid.adapter!!.itemCount)
        assertEquals(name, title(lm, lm.findFirstVisibleItemPosition()))
        assertEquals(y, lm.findViewByPosition(lm.findFirstVisibleItemPosition())!!.top)
        Abs.offline = false
        controller.destroy()
    }

    @Test fun cachedSeriesShelfRefreshesAfterDetailRemovalAndDownloadChanges() {
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        fun cache(path: String, json: JSONObject) {
            val file = Abs::class.java.getDeclaredMethod("cacheFile", String::class.java).apply { isAccessible = true }
                .invoke(Abs, path) as java.io.File
            file.parentFile!!.mkdirs()
            file.writeText(json.toString())
        }
        val track = Track("audio", ".mp3", 7, 60.0, 0.0)
        val books = (0 until 200).map { i ->
            val id = "shelf$i"
            Abs.file(id, track).apply { parentFile!!.mkdirs(); writeText("fixture") }
            JSONObject().put("id", id).put("mediaType", "book").put("media", JSONObject()
                .put("metadata", JSONObject().put("title", "Title $i"))
                .put("tracks", JSONArray().put(JSONObject().put("ino", track.ino).put("duration", track.duration)
                    .put("metadata", JSONObject().put("ext", track.ext).put("size", track.size)))))
                .also { cache("/api/items/$id?expanded=1", it) }
        }
        cache("/api/libraries", JSONObject().put("libraries", JSONArray().put(JSONObject()
            .put("id", "books").put("name", "Books").put("mediaType", "book"))))
        cache("/api/libraries/books/series?limit=1000&sort=name", JSONObject().put("results", JSONArray()
            .put(JSONObject().put("name", "Cached series").put("books", JSONArray(books)))))
        try {
            // Cached routes render immediately; failed refreshes remain offline, not expired.
            Abs.p.edit().putString("server", "http://127.0.0.1:1").putString("me", "fixture")
                .putString("acct:fixture", JSONObject().put("a", "fixture").put("r", "").toString()).commit()
            Abs.offline = true
            Abs.dlChanged()
            a.call("tab", 2)
            layout(a.content())
            views(a.content()).filterIsInstance<android.widget.TextView>()
                .single { it.text == "Cached series" }.let { (it.parent.parent as View).performClick() }
            val page = a.content().getChildAt(0)
            val grid = views(page).filterIsInstance<RecyclerView>().single()
            val lm = grid.layoutManager as GridLayoutManager
            layout(a.content())
            assertEquals(200, grid.adapter!!.itemCount)
            lm.scrollToPositionWithOffset(100, -29)
            layout(a.content())
            val first = lm.findFirstVisibleItemPosition()
            val name = title(lm, first)
            val y = lm.findViewByPosition(first)!!.top
            val removed = first + lm.spanCount // keep the visible anchor, remove another visible title
            lm.findViewByPosition(removed)!!.performClick()
            layout(a.content())
            views(a.content()).single { it.contentDescription == "Remove download of Title $removed" }.performClick()
            val dialog = org.robolectric.shadows.ShadowDialog.getLatestDialog() as androidx.appcompat.app.AlertDialog
            dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE).performClick()
            shadowOf(Looper.getMainLooper()).idle()
            assertFalse(Abs.downloaded("shelf$removed"))
            a.onBackPressedDispatcher.onBackPressed()
            layout(a.content())
            assertSame(page, a.content().getChildAt(0))
            assertSame(lm, grid.layoutManager)
            assertEquals(199, grid.adapter!!.itemCount)
            assertEquals(name, title(lm, lm.findFirstVisibleItemPosition()))
            assertEquals(y, lm.findViewByPosition(lm.findFirstVisibleItemPosition())!!.top)
            assertTrue(views(grid).filterIsInstance<android.widget.TextView>().none { it.text == "Title $removed" })

            // Download-change callbacks update this same shelf, including repeated changes
            // before layout and insertion ahead of the viewport. Do not replace its source list.
            val onDl = Main::class.java.getDeclaredField("onDl").apply { isAccessible = true }
            @Suppress("UNCHECKED_CAST")
            val refresh = onDl.get(a) as () -> Unit
            repeat(2) { i ->
                Abs.removeAll(java.io.File(Abs.mediaDir, "audio/shelf$i"))
                refresh()
            }
            layout(a.content())
            assertEquals(197, grid.adapter!!.itemCount)
            assertEquals(name, title(lm, first - 2))
            assertEquals(y, lm.findViewByPosition(first - 2)!!.top)
            Abs.file("shelf0", track).apply { parentFile!!.mkdirs(); writeText("fixture") }
            Abs.dlChanged()
            refresh()
            layout(a.content())
            assertEquals(198, grid.adapter!!.itemCount)
            assertEquals(name, title(lm, first - 1))
            assertEquals(y, lm.findViewByPosition(first - 1)!!.top)
        } finally {
            Abs.offline = false
            Abs.p.edit().remove("me").commit()
            controller.destroy()
        }
    }

    @Test fun delayedFavoritesAndMetadataUpdateTheirRetainedOwner() {
        val release = CountDownLatch(1)
        val requested = CountDownLatch(1)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { x ->
            val body = if (x.requestURI.path == "/api/me") {
                requested.countDown(); release.await(5, TimeUnit.SECONDS)
                JSONObject().put("mediaProgress", JSONArray()).put("bookmarks", JSONArray((0..195).map {
                    JSONObject().put("libraryItemId", "fav$it").put("title", "♥ Favorite")
                } + JSONObject().put("libraryItemId", "new").put("title", "♥ Favorite")))
            } else JSONObject().put("id", "new").put("media", JSONObject().put("metadata", JSONObject().put("title", "Title new")))
            val bytes = body.toString().toByteArray()
            x.sendResponseHeaders(200, bytes.size.toLong())
            x.responseBody.use { it.write(bytes) }
        }
        server.start()
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        try {
            Abs.offline = false
            val favs = JSONObject()
            repeat(200) { favs.put("fav$it", Card("fav$it", "Title $it", "").json()) }
            Abs.p.edit().putString("server", "http://127.0.0.1:" + server.address.port)
                .putString("me", "fixture").putString("acct:fixture", JSONObject().put("a", "fixture").put("r", "").toString())
                .putString("fav", favs.toString()).putString("favq", "{}").commit()
            a.call("tab", 3)
            val page = a.content().getChildAt(0)
            val grid = views(page).filterIsInstance<RecyclerView>().single()
            val lm = grid.layoutManager as GridLayoutManager
            layout(a.content())
            lm.scrollToPositionWithOffset(100, -23)
            layout(a.content())
            val name = title(lm, lm.findFirstVisibleItemPosition())
            val y = lm.findViewByPosition(lm.findFirstVisibleItemPosition())!!.top
            assertTrue(requested.await(5, TimeUnit.SECONDS))
            a.call("push", { a.call("shelf", "Details", emptyList<Card>(), 1f) })
            release.countDown()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (Abs.favs().none { it.title == "Title new" } && System.nanoTime() < deadline) {
                Thread.sleep(20); shadowOf(Looper.getMainLooper()).idle()
            }
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(197, grid.adapter!!.itemCount)
            assertTrue(Abs.favs().any { it.title == "Title new" })
            a.onBackPressedDispatcher.onBackPressed()
            layout(a.content())
            assertSame(page, a.content().getChildAt(0))
            val anchor = Abs.favs().indexOfFirst { it.title == name }
            assertTrue(anchor >= 0)
            assertEquals(name, title(lm, anchor))
            assertEquals(y, lm.findViewByPosition(anchor)!!.top)
        } finally {
            release.countDown(); server.stop(0)
            Abs.p.edit().remove("me").commit()
            controller.destroy()
        }
    }

}
