package com.borodutch.absplus

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.widget.NestedScrollView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleRegistry
import androidx.recyclerview.widget.RecyclerView
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class OfflineHomeTest {
    private fun Main.call(name: String, vararg args: Any) = Main::class.java.declaredMethods.single { it.name == name }
        .apply { isAccessible = true }.invoke(this, *args)
    private fun cache(path: String, value: JSONObject) {
        (Abs::class.java.getDeclaredMethod("cacheFile", String::class.java).apply { isAccessible = true }
            .invoke(Abs, path) as File).apply { parentFile!!.mkdirs(); writeText(value.toString()) }
    }
    private fun views(v: View): List<View> = listOf(v) + if (v is ViewGroup) (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()
    private fun layout(v: View) {
        v.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY))
        v.layout(0, 0, 1080, 300)
    }
    private fun audio(id: String, size: Int = 7) = JSONObject().put("ino", id).put("duration", 60)
        .put("metadata", JSONObject().put("ext", ".mp3").put("size", size))
    private fun episode(id: String) = JSONObject().put("id", id).put("title", "Episode $id").put("audioFile", audio(id))
    private fun seed(): Pair<List<Card>, JSONObject> {
        Abs.logout()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/login") { x ->
            x.requestBody.close()
            val data = """{"user":{"username":"fixture","accessToken":"fixture"}}""".toByteArray()
            x.sendResponseHeaders(200, data.size.toLong())
            x.responseBody.use { it.write(data) }
        }
        server.start()
        try { Abs.login("http://127.0.0.1:" + server.address.port, "fixture", "fixture", true) }
        finally { server.stop(0) }
        for (id in listOf("podcast", "book")) File(Abs.mediaDir, "audio/$id").deleteRecursively()
        val eps = JSONArray().put(episode("saved")).put(episode("recent"))
            .put(JSONObject().put("id", "missingAudio")).put(episode("zero").put("audioFile", audio("zero", 0)))
        val podcast = JSONObject().put("id", "podcast").put("mediaType", "podcast")
            .put("media", JSONObject().put("metadata", JSONObject().put("title", "Podcast")).put("episodes", eps))
        cache("/api/items/podcast?expanded=1", podcast)
        val book = JSONObject().put("id", "book").put("mediaType", "book")
            .put("media", JSONObject().put("metadata", JSONObject().put("title", "Complete book"))
                .put("tracks", JSONArray().put(audio("one")).put(audio("two"))))
        cache("/api/items/book?expanded=1", book)
        for ((id, ino) in listOf("podcast" to "saved", "book" to "one", "book" to "two")) {
            File(Abs.mediaDir, "audio/$id/$ino.mp3").apply { parentFile!!.mkdirs(); writeText("fixture") }
        }
        Abs.dlChanged()
        return listOf(Card("podcast", "Episode saved", "Podcast", "saved"), Card("podcast", "Episode recent", "Podcast", "recent"), Card.item(book)) to
            JSONObject().put("libraryItems", JSONArray().put(JSONObject(podcast.toString()).put("recentEpisode", episode("recent"))).put(book))
    }

    @Test fun exactEpisodeRequiresItsOwnCompleteFileAndInvalidatesWithDownloads() {
        val controller = Robolectric.buildActivity(Main::class.java).create()
        try {
            val (cards, _) = seed()
            assertTrue(Abs.downloaded("podcast"))
            assertTrue(Abs.downloaded(cards[0]))
            assertFalse(Abs.downloaded(cards[1]))
            assertTrue(Abs.downloaded(cards[2]))
            for (ep in listOf("missing", "missingAudio", "zero")) assertFalse(Abs.downloaded(Card("podcast", "", "", ep)))
            assertFalse(Abs.downloaded(Card("uncached", "", "", "saved")))
            File(Abs.mediaDir, "audio/podcast/recent.mp3.part").writeText("fixture")
            Abs.dlChanged()
            assertFalse(Abs.downloaded(cards[1]))
            File(Abs.mediaDir, "audio/podcast/recent.mp3").writeText("short")
            Abs.dlChanged()
            assertFalse(Abs.downloaded(cards[1]))
            File(Abs.mediaDir, "audio/podcast/recent.mp3").writeText("fixture")
            Abs.dlChanged()
            assertTrue(Abs.downloaded(cards[1]))
            Abs.remove(listOf(File(Abs.mediaDir, "audio/podcast/recent.mp3")))
            Abs.dlChanged()
            assertFalse(Abs.downloaded(cards[1]))
            assertTrue(Abs.downloaded("podcast"))
            Abs.remove(listOf(File(Abs.mediaDir, "audio/book/two.mp3")))
            Abs.dlChanged()
            assertFalse(Abs.downloaded(cards[2]))
        } finally { Abs.logout(); controller.destroy() }
    }

    @Test fun realHomeFiltersBothSectionsAndRefreshesRetainedPage() {
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        try {
            val (cards, progress) = seed()
            cache("/api/me/items-in-progress?limit=20", progress)
            cache("/api/me", JSONObject().put("mediaProgress", JSONArray()).put("bookmarks", JSONArray()))
            Abs.p.edit().putString("hist", JSONArray(cards.map { it.json().put("at", 1) }).toString()).commit()
            Abs.offline = true
            a.call("tab", 0)
            val content = Main::class.java.getDeclaredField("content").apply { isAccessible = true }.get(a) as FrameLayout
            val page = content.getChildAt(0) as NestedScrollView
            layout(content)
            val cont = views(page).filterIsInstance<RecyclerView>().single()
            fun count(title: String) = views(page).filterIsInstance<TextView>().count { it.text == title }
            assertEquals(1, cont.adapter!!.itemCount) // only the complete book, not recent's saved sibling
            assertEquals(0, count("Episode recent"))
            assertEquals(1, count("Episode saved"))
            File(Abs.mediaDir, "audio/podcast/recent.mp3").writeText("fixture")
            Abs.dlChanged()
            val onDl = Main::class.java.getDeclaredField("onDl").apply { isAccessible = true }
            @Suppress("UNCHECKED_CAST")
            (onDl.get(a) as () -> Unit).invoke()
            layout(content)
            assertSame(page, content.getChildAt(0))
            assertEquals(2, cont.adapter!!.itemCount)
            assertEquals(2, count("Episode recent"))
            page.scrollTo(0, 80)
            val y = page.scrollY
            assertTrue(y > 0)
            a.call("push", { a.call("item", "podcast") })
            Abs.remove(listOf(File(Abs.mediaDir, "audio/podcast/recent.mp3")))
            Abs.dlChanged()
            a.onBackPressedDispatcher.onBackPressed()
            layout(content)
            assertSame(page, content.getChildAt(0))
            assertEquals(y, page.scrollY)
            assertEquals(1, cont.adapter!!.itemCount)
            assertEquals(0, count("Episode recent"))
            assertEquals(1, count("Episode saved"))
        } finally {
            Abs.offline = false
            Abs.p.edit().remove("me").commit()
            controller.destroy()
        }
    }
}
