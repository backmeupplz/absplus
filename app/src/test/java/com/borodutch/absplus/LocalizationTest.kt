package com.borodutch.absplus

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.view.View
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import com.sun.net.httpserver.HttpServer
import java.io.File
import java.net.InetSocketAddress
import java.util.Locale

/** Every translation has every string, and each one formats with the arguments the code passes for the English one. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LocalizationTest {
    private val folders = mapOf(
        "ar" to "ar", "de" to "de", "es" to "es", "fr" to "fr", "hi" to "hi", "id" to "in", "it" to "it", "ja" to "ja",
        "ko" to "ko", "nl" to "nl", "pl" to "pl", "pt-BR" to "pt", "pt-PT" to "pt-rPT", "ru" to "ru", "sv" to "sv",
        "th" to "th", "tr" to "tr", "uk" to "uk", "vi" to "vi", "zh-Hans" to "b+zh+Hans", "zh-Hant" to "b+zh+Hant",
    )
    private val placeholder = Regex("""%(?:(\d+)\$)?(?:\.\d+)?([sdf%])""")

    private fun context(tag: String): Context = RuntimeEnvironment.getApplication()
        .createConfigurationContext(Configuration().apply { setLocale(Locale.forLanguageTag(tag)) })

    /** name to raw text (the "other" form for plurals) of the strings in one values folder */
    private fun names(folder: String): Map<String, String> {
        val xml = File("src/main/res/$folder/strings.xml").readText()
        return Regex("""<string name="([^"]+)"(?![^>]*translatable="false")[^>]*>(.*?)</string>""").findAll(xml).associate { it.groupValues[1] to it.groupValues[2] } +
            Regex("""<plurals name="([^"]+)">.*?<item quantity="other">(.*?)</item>""", RegexOption.DOT_MATCHES_ALL).findAll(xml)
                .associate { it.groupValues[1] to it.groupValues[2] }
    }

    /** sample arguments matching the English text's placeholders, in argument order */
    private fun args(english: String): Array<Any> {
        val types = sortedMapOf<Int, Char>()
        var next = 0
        placeholder.findAll(english).filter { it.groupValues[2] != "%" }.forEach {
            types[it.groupValues[1].toIntOrNull() ?: ++next] = it.groupValues[2][0]
        }
        return types.values.mapIndexed { i, t -> if (t == 's') "ARG$i" else if (t == 'f') 1.5 else 7 + i }.toTypedArray()
    }

    @Test fun everyLanguageHasEveryStringAndItFormats() {
        val english = names("values")
        val en = context("en-US")
        for ((tag, folder) in folders) {
            assertEquals("$tag strings", english.keys, names("values-$folder").keys)
            val c = context(tag)
            var same = 0
            for ((name, text) in english) {
                val a = args(text)
                val id = c.resources.getIdentifier(name, "string", c.packageName)
                val shown = if (id != 0) c.getString(id, *a) else {
                    val pid = c.resources.getIdentifier(name, "plurals", c.packageName)
                    listOf(0, 1, 2, 3, 5, 11, 21, 100).map { n -> c.resources.getQuantityString(pid, n, n, *a.drop(1).toTypedArray()) }.last()
                }
                a.filterIsInstance<String>().forEach { assertTrue("$tag $name: $shown", it in shown) }
                if (id != 0 && shown == en.getString(id, *a)) same++
            }
            assertTrue("$tag: $same of ${english.size} strings are still English", same < english.size / 10)
        }
    }

    @Test fun followsTheDeviceLanguage() {
        fun tab(tag: String) = context(tag).getString(R.string.tab_library)
        assertEquals(tab("zh-Hans"), tab("zh-CN"))
        assertEquals(tab("zh-Hans"), tab("zh-Hans-HK"))
        assertEquals(tab("zh-Hant"), tab("zh-TW"))
        assertEquals(tab("zh-Hant"), tab("zh-HK"))
        assertEquals(tab("pt-BR"), tab("pt"))
        assertEquals(tab("es"), tab("es-MX"))
        assertEquals(context("id").getString(R.string.empty_library), context("in").getString(R.string.empty_library))
        assertEquals("Library", tab("en-GB"))
        assertTrue(context("pt-PT").getString(R.string.hint_username) != context("pt-BR").getString(R.string.hint_username))
    }

    @Test fun signInFailuresAreTranslated() {
        val de = context("de")
        Abs.init(RuntimeEnvironment.getApplication()); Abs.logout()
        fun shown(url: String) = de.errorText(runCatching { Abs.login(url, "fixture", "fixture", true) }.exceptionOrNull()!!)
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/login") { x -> // some web page that isn't Audiobookshelf
            x.requestBody.close()
            val bytes = "<!DOCTYPE html><title>Router</title>".toByteArray()
            x.sendResponseHeaders(200, bytes.size.toLong())
            x.responseBody.use { it.write(bytes) }
        }
        server.start()
        try { assertEquals(de.getString(R.string.err_invalid_login), shown("http://127.0.0.1:" + server.address.port)) }
        finally { server.stop(0) }
        assertEquals(de.getString(R.string.err_invalid_url), shown("htps://example.com"))
        assertEquals(de.getString(R.string.err_unreachable), de.errorText(java.net.UnknownHostException("nowhere.invalid")))
        assertEquals(de.getString(R.string.err_unreachable), de.errorText(java.net.ConnectException("Failed to connect")))
        assertTrue(de.getString(R.string.err_unreachable) != context("en-US").getString(R.string.err_unreachable))
    }

    @Test fun sizeUnitsAndNameListsFollowTheLanguage() {
        // Main.mb and the share confirmation use these with the UI context's locale.
        fun size(tag: String) = android.text.format.Formatter.formatShortFileSize(context(tag), 5_000_000)
        assertTrue(size("en-US"), "MB" in size("en-US"))
        assertTrue(size("ru"), "МБ" in size("ru"))
        assertTrue(size("uk"), "МБ" in size("uk"))
        assertTrue(size("ar"), "MB" !in size("ar"))
        fun names(tag: String) = android.icu.text.ListFormatter.getInstance(context(tag).resources.configuration.locales[0]).format(listOf("Alice", "Bob"))
        assertEquals("Alice and Bob", names("en-US"))
        assertEquals("Alice и Bob", names("ru"))
        assertTrue(names("ar"), "و" in names("ar") && "and" !in names("ar"))
    }

    @Test fun arabicIsRightToLeft() {
        val app = RuntimeEnvironment.getApplication()
        assertTrue(app.applicationInfo.flags and ApplicationInfo.FLAG_SUPPORTS_RTL != 0)
        assertEquals(View.LAYOUT_DIRECTION_RTL, context("ar").resources.configuration.layoutDirection)
    }
}
