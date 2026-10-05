package com.borodutch.absplus

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

/** Native filesystem/SharedPreferences regression coverage; no server, credentials or download worker. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29], manifest = Config.NONE)
class DownloadRemovalTest {
    private lateinit var context: Context
    private val a = episode("podcast", "a")
    private val b = episode("podcast", "b")
    private val c = episode("podcast", "c")
    private val d = episode("podcast", "d")
    private val other = episode("other-podcast", "e")
    private val otherPartial = episode("other-podcast", "f")

    @Before fun setUp() {
        context = RuntimeEnvironment.getApplication()
        resetProcessState()
        Abs.init(context)
        assertTrue(Abs.p.edit().clear().commit())
        Abs.dir.deleteRecursively()
        Abs.dir.mkdirs()
        File(context.filesDir, "json").deleteRecursively()
        File(context.filesDir, "json").mkdirs()
        cache(a, b, c, d)
        cache(other, otherPartial)
        complete(a)
        complete(b)
        complete(other)
        partial(c, 3)
        partial(d, 5)
        partial(otherPartial, 7)
        // Seed the on-disk queue as if interrupted, then use the production deserializer/measurement.
        assertTrue(Abs.p.edit().putString("dlq", JSONArray().apply {
            listOf(c, d, otherPartial).forEach { put(it.json()) }
        }.toString()).commit())
        Dl.load()
        assertQueue(c, d, otherPartial)
        assertComplete(a)
        assertComplete(b)
        assertTrue(Abs.downloaded(a.item)) // Warm item and episode memoization before removal.
        assertTrue(Dl.idle)
    }

    @After fun tearDown() {
        assertTrue("Tests must never start the network worker", Dl.idle)
        Dl.clear()
        Abs.p.edit().clear().commit()
        Abs.dir.deleteRecursively()
        File(context.filesDir, "json").deleteRecursively()
        resetProcessState()
    }

    @Test fun removingOneCompleteEpisodePreservesSiblingsAndPartialQueueAcrossReload() {
        // Main.removeDl delegates here and then invalidates the downloaded-state memo.
        Abs.remove(a.tracks.map { Abs.file(a.item, it) })
        Abs.dlChanged()

        assertRemoved(a)
        assertComplete(b)
        assertPartial(c, 3)
        assertPartial(d, 5)
        assertComplete(other)
        assertPartial(otherPartial, 7)
        assertQueue(c, d, otherPartial)
        assertTrue(Abs.downloaded(a.item))
        assertEquals(setOf(a.item, other.item), Abs.downloads().map { it.name }.toSet())
        reload()
        assertRemoved(a)
        assertComplete(b)
        assertComplete(other)
        assertPartial(c, 3)
        assertPartial(d, 5)
        assertPartial(otherPartial, 7)
        assertQueue(c, d, otherPartial)
        assertTrue(Abs.downloaded(a.item))
    }

    @Test fun cancellingPartialEpisodePreservesOtherPartialsAndQueueAcrossReload() {
        Dl.cancel(c)
        Abs.dlChanged() // Same invalidation used by Main's cancellation callers.

        assertRemoved(c)
        assertComplete(a)
        assertComplete(b)
        assertPartial(d, 5)
        assertComplete(other)
        assertPartial(otherPartial, 7)
        assertQueue(d, otherPartial)
        reload()
        assertRemoved(c)
        assertComplete(a)
        assertComplete(b)
        assertPartial(d, 5)
        assertComplete(other)
        assertPartial(otherPartial, 7)
        assertQueue(d, otherPartial)
    }

    @Test fun removeAllDeletesOnlySelectedItemAndItsQueueAcrossReload() {
        Abs.removeAll(File(Abs.dir, a.item))

        listOf(a, b, c, d).forEach(::assertRemoved)
        assertFalse(File(Abs.dir, a.item).exists())
        assertFalse(Abs.downloaded(a.item))
        assertComplete(other)
        assertPartial(otherPartial, 7)
        assertQueue(otherPartial)
        assertEquals(listOf(other.item), Abs.downloads().map { it.name })
        reload()
        listOf(a, b, c, d).forEach(::assertRemoved)
        assertFalse(File(Abs.dir, a.item).exists())
        assertFalse(Abs.downloaded(a.item))
        assertComplete(other)
        assertPartial(otherPartial, 7)
        assertQueue(otherPartial)
        assertEquals(listOf(other.item), Abs.downloads().map { it.name })
    }

    @Test fun removingLastCompleteSiblingDoesNotDeleteRemainingPartialFolder() {
        Abs.remove(listOf(file(a), file(b)))
        Abs.dlChanged()

        assertRemoved(a)
        assertRemoved(b)
        assertTrue(File(Abs.dir, a.item).isDirectory)
        assertFalse(Abs.downloaded(a.item))
        assertEquals(listOf(other.item), Abs.downloads().map { it.name })
        reload()
        assertRemoved(a)
        assertRemoved(b)
        assertPartial(c, 3)
        assertPartial(d, 5)
        assertComplete(other)
        assertPartial(otherPartial, 7)
        assertQueue(c, d, otherPartial)
        assertFalse(Abs.downloaded(a.item))
    }

    private fun episode(item: String, ep: String) = Now(item, ep, "Episode $ep", "Fixture author",
        listOf(Track("track-$ep", ".mp3", 16, 30.0, 0.0)))

    private fun file(n: Now) = Abs.file(n.item, n.tracks.single())
    private fun part(n: Now) = File(file(n).path + ".part")
    private fun bytes(n: Now, size: Int) = ByteArray(size) { n.ep!!.single().code.toByte() }
    private fun complete(n: Now) = file(n).apply { parentFile!!.mkdirs(); writeBytes(bytes(n, 16)) }
    private fun partial(n: Now, size: Int) = part(n).apply { parentFile!!.mkdirs(); writeBytes(bytes(n, size)) }
    private fun card(n: Now) = Card(n.item, n.title, n.author, n.ep)

    private fun assertComplete(n: Now) {
        assertArrayEquals(bytes(n, 16), file(n).readBytes())
        assertTrue(Abs.done(n.item, n.tracks.single()))
        assertTrue(Abs.downloaded(card(n)))
        assertEquals("file", Abs.uri(n.item, n.tracks.single()).scheme)
        assertEquals(file(n).absolutePath, Abs.uri(n.item, n.tracks.single()).path)
    }

    private fun assertPartial(n: Now, size: Int) {
        assertFalse(file(n).exists())
        assertArrayEquals(bytes(n, size), part(n).readBytes())
        assertFalse(Abs.done(n.item, n.tracks.single()))
        assertFalse(Abs.downloaded(card(n)))
        assertEquals(size.toLong(), Dl.job(n.key)!!.got)
    }

    private fun assertRemoved(n: Now) {
        assertFalse(file(n).exists())
        assertFalse(part(n).exists())
        assertFalse(Abs.done(n.item, n.tracks.single()))
        assertFalse(Abs.downloaded(card(n)))
    }

    private fun assertQueue(vararg expected: Now) {
        assertEquals(expected.map { it.json().toString() }, Dl.jobs.map { it.n.json().toString() })
        val persisted = JSONArray(Abs.p.getString("dlq", "[]"))
        assertEquals(expected.map { it.json().toString() }, (0 until persisted.length()).map { Now.of(persisted.getJSONObject(it)).json().toString() })
    }

    private fun cache(vararg episodes: Now) {
        val json = JSONObject().put("id", episodes.first().item).put("media", JSONObject()
            .put("metadata", JSONObject().put("title", "Fixture podcast").put("author", "Fixture author"))
            .put("episodes", JSONArray().apply {
                episodes.forEach { n ->
                    val t = n.tracks.single()
                    put(JSONObject().put("id", n.ep).put("audioFile", JSONObject().put("ino", t.ino)
                        .put("duration", t.duration).put("metadata", JSONObject().put("ext", t.ext).put("size", t.size))))
                }
            }))
        val path = "/api/items/${episodes.first().item}?expanded=1"
        File(File(context.filesDir, "json"), path.replace(Regex("[^A-Za-z0-9]"), "_")).writeText(json.toString())
    }

    private fun reload() {
        val queue = Abs.p.getString("dlq", null)
        val cached = listOf(a.item, other.item).associateWith { Abs.cached("/api/items/$it?expanded=1") }
        assertTrue(cached.values.all { it != null })
        assertTrue(Abs.p.edit().commit()) // Flush prior apply() writes before dropping process references.
        resetProcessState()
        Abs.init(context)
        Dl.load()
        Abs.offline = true
        assertEquals(queue, Abs.p.getString("dlq", null))
        cached.forEach { (id, json) -> assertEquals(json, Abs.cached("/api/items/$id?expanded=1")) }
    }

    /** Simulated process restart: retain disk/preferences, discard singleton queue, paths and memoized state. */
    private fun resetProcessState() {
        Dl.clear()
        Dl.onChange = null
        Abs.now = null
        Abs.offline = false
        Abs.progress = emptyMap()
        Abs.dlChanged()
        listOf("p", "dir", "cacheDir").forEach { name ->
            Abs::class.java.getDeclaredField(name).apply { isAccessible = true }.set(null, null)
        }
    }
}
