package com.borodutch.absplus

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleRegistry
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.textfield.TextInputEditText
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
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class OfflineLibraryTest {
    private fun Main.call(name: String, vararg args: Any) = Main::class.java.declaredMethods.single { it.name == name }
        .apply { isAccessible = true }.invoke(this, *args)
    private fun views(v: View): List<View> = listOf(v) + if (v is ViewGroup) (0 until v.childCount).flatMap { views(v.getChildAt(it)) } else emptyList()
    private fun layout(v: View) {
        v.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1800, View.MeasureSpec.EXACTLY))
        v.layout(0, 0, 1080, 1800)
    }
    private fun seed(id: String, podcast: Boolean = false, empty: Boolean = false, size: Int = 7) {
        File(Abs.mediaDir, "audio/$id").apply { deleteRecursively(); mkdirs() }
        val audio = listOf("one", "two").map { JSONObject().put("ino", it).put("duration", 60)
            .put("metadata", JSONObject().put("ext", ".mp3").put("size", size)) }
        val media = JSONObject().put("metadata", JSONObject().put("title", "Fixture $id"))
        if (podcast) media.put("episodes", JSONArray(audio.mapIndexed { i, a -> JSONObject().put("id", "ep$i").put("audioFile", a) }))
        else media.put("tracks", JSONArray(if (empty) emptyList() else audio))
        val cache = Abs::class.java.getDeclaredMethod("cacheFile", String::class.java).apply { isAccessible = true }
            .invoke(Abs, "/api/items/$id?expanded=1") as File
        cache.parentFile!!.mkdirs()
        cache.writeText(JSONObject().put("id", id).put("mediaType", if (podcast) "podcast" else "book").put("media", media).toString())
    }
    private fun save(id: String, track: String, bytes: String = "fixture") = File(Abs.mediaDir, "audio/$id/$track.mp3").writeText(bytes)

    @Test fun realLibraryFiltersCompleteTitlesButStorageKeepsPartialFiles() {
        // Reset before Main can schedule reads against another test's stopped server.
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        val controller = Robolectric.buildActivity(Main::class.java).create()
        val a = controller.get()
        (a.lifecycle as LifecycleRegistry).handleLifecycleEvent(Lifecycle.Event.ON_START)
        try {
            val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
            server.createContext("/login") { x ->
                x.requestBody.close()
                val bytes = """{"user":{"id":"library-fixture-id","username":"fixture","accessToken":"fixture"}}""".toByteArray()
                x.sendResponseHeaders(200, bytes.size.toLong())
                x.responseBody.use { it.write(bytes) }
            }
            server.start()
            try { Abs.login("http://127.0.0.1:" + server.address.port, "fixture", "fixture", true) }
            finally { server.stop(0) }
            val ids = listOf("partial", "complete", "zero", "podcast", "podcast-zero", "empty", "missing-zero")
            ids.forEach { seed(it, it.startsWith("podcast"), it == "empty", if (it == "missing-zero") 0 else 7) }
            save("partial", "one"); save("complete", "one"); save("complete", "two"); save("podcast", "one")
            listOf("zero", "podcast-zero").forEach { save(it, "one", "short") }
            listOf("empty", "missing-zero").forEach { save(it, "unrelated", "short") }
            Abs.offline = true
            Abs.dlChanged()
            a.call("tab", 1)
            val content = Main::class.java.getDeclaredField("content").apply { isAccessible = true }.get(a) as FrameLayout
            val page = content.getChildAt(0)
            val grid = views(page).filterIsInstance<RecyclerView>().single()
            val search = views(page).filterIsInstance<TextInputEditText>().single()
            search.setText("Fixture ") // Other test classes can leave synthetic downloads in the sandbox.
            layout(content)
            assertEquals(2, grid.adapter!!.itemCount)
            assertTrue(Abs.downloaded("complete")); assertTrue(Abs.downloaded("podcast"))
            for (id in ids - setOf("complete", "podcast")) assertFalse(id, Abs.downloaded(id))
            assertTrue(Abs.downloads().map { it.name }.containsAll(ids))
            search.setText("Fixture partial")
            assertEquals(0, grid.adapter!!.itemCount)
            save("partial", "two")
            Abs.dlChanged()
            val onDl = Main::class.java.getDeclaredField("onDl").apply { isAccessible = true }
            @Suppress("UNCHECKED_CAST")
            (onDl.get(a) as () -> Unit).invoke()
            assertSame(page, content.getChildAt(0))
            assertEquals(1, grid.adapter!!.itemCount)
            a.call("push", { a.call("downloads") })
            layout(content)
            assertTrue(views(content).filterIsInstance<TextView>().any { it.text == "Fixture partial" })
            File(Abs.mediaDir, "audio/partial/two.mp3").delete()
            Abs.dlChanged()
            a.onBackPressedDispatcher.onBackPressed()
            layout(content)
            assertSame(page, content.getChildAt(0))
            assertEquals("Fixture partial", search.text.toString())
            assertEquals(0, grid.adapter!!.itemCount)
            assertTrue(File(Abs.mediaDir, "audio/partial/one.mp3").isFile)
            Abs.removeAll(File(Abs.mediaDir, "audio/partial"))
            assertFalse(Abs.downloads().any { it.name == "partial" })
            File(Abs.mediaDir, "audio/podcast/one.mp3").delete()
            Abs.dlChanged()
            assertFalse(Abs.downloaded("podcast"))
        } finally {
            listOf("partial", "complete", "zero", "podcast", "podcast-zero", "empty", "missing-zero")
                .forEach { File(Abs.mediaDir, "audio/$it").deleteRecursively() }
            Abs.dlChanged()
            Abs.logout()
            controller.destroy()
        }
    }
}
