package com.borodutch.absplus

import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleRegistry
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.chip.Chip
import com.google.android.material.textfield.TextInputEditText
import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LibraryRecoveryTest {
    private fun Main.call(name: String, vararg args: Any) = Main::class.java.declaredMethods.single { it.name == name }
        .apply { isAccessible = true }.invoke(this, *args)
    private fun Main.content() = Main::class.java.getDeclaredField("content").let {
        it.isAccessible = true; it.get(this) as FrameLayout
    }
    private fun views(v: View): List<View> = listOf(v) + if (v is ViewGroup)
        (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()
    private fun Main.grid() = views(content()).filterIsInstance<RecyclerView>().single()
    private fun Main.search() = views(content()).filterIsInstance<TextInputEditText>().single()
    private fun layout(v: View) {
        v.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1800, View.MeasureSpec.EXACTLY))
        v.layout(0, 0, 1080, 1800)
    }
    private fun await(message: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
        while (!condition() && System.nanoTime() < deadline) {
            Thread.sleep(20)
            shadowOf(Looper.getMainLooper()).idle()
        }
        assertTrue(message, condition())
    }
    private fun libraries(vararg ids: String) = JSONObject().put("libraries", JSONArray(ids.map {
        JSONObject().put("id", it).put("name", "Library $it")
    })).toString()
    private fun items(id: String) = JSONObject().put("results", JSONArray((0 until 500).map {
        JSONObject().put("id", "$id$it").put("mediaType", "book").put("media", JSONObject()
            .put("metadata", JSONObject().put("title", "$id Title $it")))
    })).toString()
    private fun cache(path: String, body: String) {
        val file = Abs::class.java.getDeclaredMethod("cacheFile", String::class.java).apply { isAccessible = true }
            .invoke(Abs, path) as File
        file.parentFile!!.mkdirs()
        file.writeText(body)
    }

    private inner class Fixture : AutoCloseable {
        val requests = CopyOnWriteArrayList<String>()
        @Volatile var membership = libraries("A", "B")
        @Volatile var membershipGate: CountDownLatch? = null
        @Volatile var aGate: CountDownLatch? = null
        @Volatile var aResult = items("A")
        val pool = Executors.newCachedThreadPool()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
            executor = pool
            createContext("/") { x ->
                val path = x.requestURI.path
                requests.add(path)
                val body = when (path) {
                    "/api/libraries" -> {
                        val result = membership
                        membershipGate?.await(30, TimeUnit.SECONDS)
                        result
                    }
                    "/api/libraries/A/items" -> { aGate?.await(30, TimeUnit.SECONDS); aResult }
                    "/api/libraries/B/items" -> items("B")
                    "/api/me" -> JSONObject().put("mediaProgress", JSONArray()).put("bookmarks", JSONArray()).toString()
                    else -> JSONObject().put("id", "A0").put("mediaType", "book").put("media", JSONObject()
                        .put("metadata", JSONObject().put("title", "Fixture details")).put("tracks", JSONArray())).toString()
                }
                val bytes = body.toByteArray()
                x.sendResponseHeaders(if (path.endsWith("/cover")) 404 else 200, bytes.size.toLong())
                x.responseBody.use { it.write(bytes) }
            }
            start()
        }
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        init {
            (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
            Abs.logout()
            Abs.offline = false
            Abs.p.edit().putString("server", "http://127.0.0.1:" + server.address.port)
                .putString("lib", "A").putString("me", "fixture")
                .putString("acct:fixture", JSONObject().put("a", "fixture").put("r", "").toString()).commit()
        }
        fun open() { a.call("tab", 1) }
        fun details() { a.call("push", { a.call("item", "A0"); Unit }) }
        override fun close() {
            membershipGate?.countDown(); aGate?.countDown()
            controller.destroy()
            server.stop(0); pool.shutdownNow()
            Abs.logout() // clear this loopback server’s JSON as well as preferences
            Abs.offline = false
        }
    }

    @Test fun validNonFirstSelectionIsPreserved() {
        Fixture().use { f ->
            Abs.p.edit().putString("lib", "B").commit()
            f.open()
            await("B loaded") { f.a.grid().adapter!!.itemCount == 500 }
            assertEquals("B", Abs.p.getString("lib", null))
            assertFalse("do not fall back when B is still available", "/api/libraries/A/items" in f.requests)
            assertEquals("Library B", views(f.a.content()).filterIsInstance<Chip>().single { it.isChecked }.text.toString())
        }
    }

    @Test fun missingSelectionChoosesFirstAvailableLibrary() {
        Fixture().use { f ->
            Abs.p.edit().remove("lib").commit()
            f.open()
            await("first available library loaded") { f.a.grid().adapter!!.itemCount == 500 }
            assertEquals("A", Abs.p.getString("lib", null))
            assertEquals(1, f.requests.count { it == "/api/libraries" })
        }
    }

    @Test fun staleCachedSelectionWaitsForFreshMembershipBeforeRequestingItems() {
        Fixture().use { f ->
            cache("/api/libraries", libraries("A", "B"))
            cache("/api/libraries/A/items?minified=1&sort=media.metadata.title", items("A"))
            f.membership = libraries("B")
            val gate = CountDownLatch(1)
            f.membershipGate = gate
            f.open()
            await("membership requested") { "/api/libraries" in f.requests }
            assertEquals(0, f.a.grid().adapter!!.itemCount)
            assertFalse(f.requests.any { it.endsWith("/items") })
            gate.countDown()
            await("B selected and loaded") { Abs.p.getString("lib", null) == "B" && f.a.grid().adapter!!.itemCount == 500 }
            assertFalse("never request removed A", "/api/libraries/A/items" in f.requests)
            assertEquals("Library B", views(f.a.content()).filterIsInstance<Chip>().single { it.isChecked }.text.toString())
            layout(f.a.content())
            assertTrue(views(f.a.grid()).filterIsInstance<TextView>().any { it.text == "B Title 0" })
        }
    }

    @Test fun revocationOnBackResetsContextAndRejectsDelayedAResponse() {
        Fixture().use { f ->
            cache("/api/libraries/A/items?minified=1&sort=media.metadata.title", items("A"))
            val gate = CountDownLatch(1)
            f.aGate = gate
            f.aResult = items("Late A")
            f.open()
            await("A request started") { "/api/libraries/A/items" in f.requests && f.a.grid().adapter!!.itemCount == 500 }
            val oldGrid = f.a.grid()
            f.a.search().setText("A Title 3")
            layout(f.a.content())
            val lm = oldGrid.layoutManager as GridLayoutManager
            lm.scrollToPositionWithOffset(80, -29)
            layout(f.a.content())
            assertTrue(lm.findFirstVisibleItemPosition() > 0)
            f.details()
            f.membership = libraries("B")
            f.a.onBackPressedDispatcher.onBackPressed()
            await("recover B after Back") { Abs.p.getString("lib", null) == "B" && f.a.grid().adapter!!.itemCount == 500 }
            assertEquals("", f.a.search().text.toString())
            assertNotSame(oldGrid, f.a.grid())
            layout(f.a.content())
            val bGrid = f.a.grid()
            val bLm = bGrid.layoutManager as GridLayoutManager
            assertEquals(0, bLm.findFirstVisibleItemPosition())
            gate.countDown()
            await("A response cached") { Abs.cached("/api/libraries/A/items?minified=1&sort=media.metadata.title") == f.aResult }
            Thread.sleep(50)
            shadowOf(Looper.getMainLooper()).idle()
            layout(f.a.content())
            assertSame(bGrid, f.a.grid())
            assertTrue(views(bGrid).filterIsInstance<TextView>().any { it.text == "B Title 0" })
            assertFalse(views(bGrid).filterIsInstance<TextView>().any { it.text.contains("A Title") })
            assertEquals(1, f.requests.count { it == "/api/libraries/A/items" })
        }
    }

    @Test fun explicitSwitchRejectsOldMembershipAndItemsWithoutStealingDetailPage() {
        Fixture().use { f ->
            cache("/api/libraries/A/items?minified=1&sort=media.metadata.title", items("A"))
            val aGate = CountDownLatch(1)
            f.aGate = aGate
            f.aResult = items("Late A")
            f.open()
            await("A list") { f.a.grid().adapter!!.itemCount == 500 && "/api/libraries/A/items" in f.requests }
            f.a.search().setText("A Title 3")
            layout(f.a.content())
            (f.a.grid().layoutManager as GridLayoutManager).scrollToPositionWithOffset(80, -29)
            layout(f.a.content())
            val oldMembership = CountDownLatch(1)
            f.membershipGate = oldMembership
            val count = f.requests.count { it == "/api/libraries" }
            f.details()
            f.a.onBackPressedDispatcher.onBackPressed()
            await("old refresh requested") { f.requests.count { it == "/api/libraries" } > count }
            f.membership = libraries("B")
            f.membershipGate = null
            views(f.a.content()).filterIsInstance<Chip>().single { it.text == "Library B" }.performClick()
            await("B loaded") { Abs.p.getString("lib", null) == "B" && f.a.grid().adapter!!.itemCount == 500 }
            assertEquals("", f.a.search().text.toString())
            layout(f.a.content())
            assertEquals(0, (f.a.grid().layoutManager as GridLayoutManager).findFirstVisibleItemPosition())
            val bPage = f.a.content().getChildAt(0)
            f.details()
            val details = f.a.content().getChildAt(0)
            oldMembership.countDown(); aGate.countDown()
            await("old A completed") { Abs.cached("/api/libraries/A/items?minified=1&sort=media.metadata.title") == f.aResult }
            Thread.sleep(50); shadowOf(Looper.getMainLooper()).idle()
            assertSame(details, f.a.content().getChildAt(0))
            assertEquals("B", Abs.p.getString("lib", null))
            f.a.onBackPressedDispatcher.onBackPressed()
            assertSame(bPage, f.a.content().getChildAt(0))
            layout(f.a.content())
            assertTrue(views(f.a.grid()).filterIsInstance<TextView>().any { it.text == "B Title 0" })
            assertEquals(1, f.requests.count { it == "/api/libraries/A/items" })
        }
    }

    @Test fun membershipRecoveryWhileHiddenDoesNotReplaceDetails() {
        Fixture().use { f ->
            f.membership = libraries("B")
            val gate = CountDownLatch(1)
            f.membershipGate = gate
            f.open()
            await("membership started") { "/api/libraries" in f.requests }
            val libraryPage = f.a.content().getChildAt(0)
            f.details()
            val details = f.a.content().getChildAt(0)
            gate.countDown()
            await("hidden B loaded") { Abs.p.getString("lib", null) == "B" &&
                views(libraryPage).filterIsInstance<RecyclerView>().single().adapter!!.itemCount == 500 }
            assertSame(details, f.a.content().getChildAt(0))
            f.a.onBackPressedDispatcher.onBackPressed()
            await("B available on return") { f.a.grid().adapter!!.itemCount == 500 }
            assertFalse("no stale A request", "/api/libraries/A/items" in f.requests)
        }
    }

    @Test fun emptyMembershipClearsSelectionAndTitlesWithoutStaleRequests() {
        Fixture().use { f ->
            f.open()
            await("A loaded") { f.a.grid().adapter!!.itemCount == 500 }
            f.a.search().setText("A Title")
            f.details()
            f.membership = libraries()
            val itemRequests = f.requests.count { it.endsWith("/items") }
            f.a.onBackPressedDispatcher.onBackPressed()
            await("empty selection") { !Abs.p.contains("lib") }
            assertEquals("", f.a.search().text.toString())
            assertEquals(0, f.a.grid().adapter!!.itemCount)
            assertTrue(views(f.a.content()).filterIsInstance<Chip>().isEmpty())
            assertTrue(views(f.a.content()).filterIsInstance<TextView>().any { it.text == "No libraries available." && it.visibility == View.VISIBLE })
            assertEquals(itemRequests, f.requests.count { it.endsWith("/items") })
            // Re-entering the tab must not resurrect cached A or a stored selection.
            val memberships = f.requests.count { it == "/api/libraries" }
            f.open()
            await("fresh empty membership") { f.requests.count { it == "/api/libraries" } > memberships &&
                views(f.a.content()).filterIsInstance<TextView>().any { it.text == "No libraries available." && it.visibility == View.VISIBLE } }
            assertFalse(Abs.p.contains("lib"))
            assertEquals(itemRequests, f.requests.count { it.endsWith("/items") })
        }
    }

    @Test fun sameLibraryRefreshPreservesAnchorAfterCompletion() {
        Fixture().use { f ->
            f.open()
            await("A loaded") { f.a.grid().adapter!!.itemCount == 500 }
            val page = f.a.content().getChildAt(0)
            val grid = f.a.grid()
            f.a.search().setText("A Title 3")
            layout(f.a.content())
            val lm = grid.layoutManager as GridLayoutManager
            lm.scrollToPositionWithOffset(80, -29)
            layout(f.a.content())
            val first = lm.findFirstVisibleItemPosition()
            val offset = lm.findViewByPosition(first)!!.top
            repeat(3) {
                val count = f.requests.count { it == "/api/libraries/A/items" }
                f.details()
                f.a.onBackPressedDispatcher.onBackPressed()
                await("same-library refresh requested") { f.requests.count { it == "/api/libraries/A/items" } > count }
                Thread.sleep(100)
                shadowOf(Looper.getMainLooper()).idle()
                layout(f.a.content())
                assertSame(page, f.a.content().getChildAt(0))
                assertSame(grid, f.a.grid())
                assertEquals("A Title 3", f.a.search().text.toString())
                assertEquals(first, lm.findFirstVisibleItemPosition())
                assertEquals(offset, lm.findViewByPosition(first)!!.top)
            }
        }
    }

    @Test fun mountedReconnectRevalidatesMembershipBeforeRevokedTitlesAndClearsEmptyContext() {
        Fixture().use { f ->
            f.open()
            await("A loaded") { f.a.grid().adapter!!.itemCount == 500 }
            val page = f.a.content().getChildAt(0)
            val oldGrid = f.a.grid()
            f.a.search().setText("A Title 3")
            Abs.offline = true
            f.a.call("refreshConnection")
            f.membership = libraries("B")
            val gate = CountDownLatch(1)
            f.membershipGate = gate
            val memberships = f.requests.count { it == "/api/libraries" }
            val aRequests = f.requests.count { it == "/api/libraries/A/items" }
            Abs.offline = false
            f.a.call("refreshConnection")
            await("fresh membership pending") { f.requests.count { it == "/api/libraries" } > memberships }
            assertSame(page, f.a.content().getChildAt(0))
            assertSame(oldGrid, f.a.grid())
            assertEquals("A Title 3", f.a.search().text.toString())
            assertFalse("no B titles before authorization", "/api/libraries/B/items" in f.requests)
            assertEquals(aRequests, f.requests.count { it == "/api/libraries/A/items" })
            gate.countDown()
            await("reconnect selects B") { Abs.p.getString("lib", null) == "B" && f.a.grid().adapter!!.itemCount == 500 }
            assertSame(page, f.a.content().getChildAt(0))
            assertNotSame(oldGrid, f.a.grid())
            assertEquals("", f.a.search().text.toString())
            layout(f.a.content())
            assertEquals(0, (f.a.grid().layoutManager as GridLayoutManager).findFirstVisibleItemPosition())
            assertEquals(aRequests, f.requests.count { it == "/api/libraries/A/items" })
            Abs.offline = true
            f.a.call("refreshConnection")
            f.membership = libraries()
            val itemRequests = f.requests.count { it.endsWith("/items") }
            Abs.offline = false
            f.a.call("refreshConnection")
            await("empty reconnect clears selection") { !Abs.p.contains("lib") }
            assertSame(page, f.a.content().getChildAt(0))
            assertEquals(0, f.a.grid().adapter!!.itemCount)
            assertTrue(views(page).filterIsInstance<TextView>().any { it.text == "No libraries available." && it.visibility == View.VISIBLE })
            assertEquals(itemRequests, f.requests.count { it.endsWith("/items") })
        }
    }

    @Test fun selectedChipRemainsSelectedOnRepeatedTapWithoutResettingContext() {
        Fixture().use { f ->
            f.open()
            await("A loaded") { f.a.grid().adapter!!.itemCount == 500 }
            val page = f.a.content().getChildAt(0)
            val grid = f.a.grid()
            val search = f.a.search()
            search.setText("A Title 3")
            layout(f.a.content())
            val lm = grid.layoutManager as GridLayoutManager
            lm.scrollToPositionWithOffset(80, -29)
            layout(f.a.content())
            val first = lm.findFirstVisibleItemPosition()
            val offset = lm.findViewByPosition(first)!!.top
            assertTrue(first > 0)
            val chip = views(f.a.content()).filterIsInstance<Chip>().single { it.isChecked }
            repeat(3) {
                chip.performClick()
                layout(f.a.content())
                assertEquals("A", Abs.p.getString("lib", null))
                assertTrue("selected library must remain visibly selected", chip.isChecked)
                assertSame(chip, views(f.a.content()).filterIsInstance<Chip>().single { it.isChecked })
                assertSame(page, f.a.content().getChildAt(0))
                assertSame(grid, f.a.grid())
                assertSame(search, f.a.search())
                assertEquals("A Title 3", search.text.toString())
                assertEquals(first, lm.findFirstVisibleItemPosition())
                assertEquals(offset, lm.findViewByPosition(first)!!.top)
            }
        }
    }
}
