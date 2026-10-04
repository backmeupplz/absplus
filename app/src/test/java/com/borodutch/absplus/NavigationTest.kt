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
}
