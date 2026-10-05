package com.borodutch.absplus

import android.content.Context
import android.net.Uri
import org.robolectric.RuntimeEnvironment
import com.sun.net.httpserver.HttpServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SessionIsolationTest {
    private class Host(val label: String) : AutoCloseable {
        val requests = CopyOnWriteArrayList<Triple<String, String?, String?>>()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val pool = Executors.newCachedThreadPool()
        val url get() = "http://127.0.0.1:" + server.address.port
        @Volatile var rejectRefresh = false
        @Volatile var expired = false
        @Volatile var omitId = false
        @Volatile var idOverride: String? = null
        @Volatile var blockedPath: String? = null
        @Volatile var redirect: String? = null
        var entered = CountDownLatch(1)
        var release = CountDownLatch(1)
        init {
            server.executor = pool
            server.createContext("/") { x ->
                val path = x.requestURI.path
                val auth = x.requestHeaders.getFirst("Authorization")
                val refresh = x.requestHeaders.getFirst("x-refresh-token")
                requests += Triple(path, auth, refresh)
                val data = x.requestBody.bufferedReader().use { it.readText() }
                if (path == blockedPath) { entered.countDown(); release.await(10, TimeUnit.SECONDS) }
                var code = 200
                val body = when (path) {
                    "/login" -> {
                        val j = JSONObject(data)
                        if (j.optString("password") == "bad") code = 401
                        user(j.getString("username"))
                    }
                    "/auth/refresh" -> { if (rejectRefresh) code = 401; user(refresh?.substringAfter("-refresh-") ?: "same") }
                    "/redirect" -> { code = 307; x.responseHeaders.add("Location", redirect); "{}" }
                    else -> "{}"
                }.toByteArray()
                x.sendResponseHeaders(code, body.size.toLong())
                x.responseBody.use { it.write(body) }
            }
            server.start()
        }
        fun user(name: String) = JSONObject().put("user", JSONObject().put("username", name).put("id", if (omitId) null else idOverride ?: "$label-id-$name")
            .put("accessToken", if (expired) "x.eyJleHAiOjF9.x" else "$label-access-$name")
            .put("refreshToken", "$label-refresh-$name")).toString()
        fun block(path: String) { blockedPath = path; entered = CountDownLatch(1); release = CountDownLatch(1) }
        override fun close() { release.countDown(); server.stop(0); pool.shutdownNow() }
    }
    private fun setup() { Abs.init(RuntimeEnvironment.getApplication()); Abs.logout() }
    private fun login(h: Host, user: String = "same", main: Boolean = true) = Abs.login(h.url, user, "fixture", main)
    private fun Host.awaitRequest() = assertTrue(entered.await(5, TimeUnit.SECONDS))
    private fun Thread.finished() { join(5000); assertFalse(isAlive) }
    private fun assertNoCrossHost(a: Host, b: Host) {
        assertTrue(a.requests.none { it.second?.contains("B-") == true || it.third?.startsWith("B-") == true })
        assertTrue(b.requests.none { it.second?.contains("A-") == true || it.third?.startsWith("A-") == true })
    }

    @Test fun refreshPreservesIdentityRejectsChangedIdAndMissingIdNeverReusesUsername() {
        setup()
        Abs.dir = RuntimeEnvironment.getApplication().getExternalFilesDir(null)!!
        Host("A").use { a ->
            for (missing in listOf(false, true)) {
                a.omitId = missing; login(a)
                val root = Abs.mediaDir
                val before = JSONObject(Abs.p.getString("acct:same", null)!!)
                Abs.token(force = true)
                val after = JSONObject(Abs.p.getString("acct:same", null)!!)
                assertEquals(before.getString("id"), after.getString("id"))
                assertEquals(before.getString("mediaIdentity"), after.getString("mediaIdentity"))
                assertEquals(root, Abs.mediaDir)
                // Simulate process reinitialization using persisted credentials, not username.
                Abs::class.java.getDeclaredField("p").apply { isAccessible = true }.set(null, null)
                Abs.init(RuntimeEnvironment.getApplication())
                assertEquals(root, Abs.mediaDir)
                login(a)
                if (missing) assertNotEquals(root, Abs.mediaDir) else assertEquals(root, Abs.mediaDir)
            }
            a.omitId = false; login(a)
            val before = JSONObject(Abs.p.getString("acct:same", null)!!)
            a.omitId = true
            Abs.token(force = true)
            val stored = Abs.p.getString("acct:same", null)
            val after = JSONObject(stored!!)
            for (key in listOf("id", "userId", "mediaIdentity")) assertEquals(before.getString(key), after.getString(key))
            a.omitId = false
            a.idOverride = "replacement-user"
            assertTrue(runCatching { Abs.token(force = true) }.exceptionOrNull() is StaleSession)
            assertEquals(stored, Abs.p.getString("acct:same", null))
        }
    }

    @Test fun rejectedRefreshThenNewHostClearsAllUserStateForSameAndDifferentNames() {
        setup()
        Host("A").use { a -> Host("B").use { b ->
            for (newName in listOf("same", "different")) {
                a.expired = false; login(a); login(a, "linked", false)
                Abs.setShares("book", setOf("linked"))
                Abs.toggleFav(Card("book", "A title", "A author"))
                Abs.p.edit().putString("dlq", "[]").putString("pos:book", "10,20").putString("hist", "[]").commit()
                val track = Track("1", ".mp3", 7, 60.0, 0.0)
                val retained = Abs.file("book", track).apply { parentFile!!.mkdirs(); writeText("fixture") }
                Abs.get("/api/me")
                val account = JSONObject(Abs.p.getString("acct:same", null)!!).put("a", "x.eyJleHAiOjF9.x")
                Abs.p.edit().putString("acct:same", account.toString()).commit()
                a.rejectRefresh = true
                assertTrue(runCatching { Abs.token() }.exceptionOrNull() is Expired)
                val epoch = Abs.mediaEpoch
                assertTrue(runCatching { Abs.login(b.url, newName, "bad", true) }.isFailure)
                assertEquals(a.url, Abs.server); assertEquals(epoch, Abs.mediaEpoch)
                assertEquals(listOf("linked"), Abs.accounts())
                login(b, newName)
                assertEquals(b.url, Abs.server); assertEquals(newName, Abs.me)
                assertTrue(Abs.accounts().isEmpty()); assertTrue(Abs.shares("book").isEmpty())
                assertTrue(Abs.favs().isEmpty()); assertTrue(Abs.progress.isEmpty())
                assertNull(Abs.p.getString("pos:book", null)); assertNull(Abs.p.getString("dlq", null))
                assertNull(Abs.cached("/api/me")); assertNull(Abs.now)
                assertTrue(retained.exists()); assertFalse(Abs.done("book", track))
                Abs.unlink("linked") // no stale A account left to revoke at B
                login(b, "linked", false); Abs.unlink("linked")
                Abs.api("GET", "/probe")
                assertEquals("Bearer B-access-$newName", b.requests.last { it.first == "/probe" }.second)
                a.rejectRefresh = false
            }
            assertNoCrossHost(a, b)
        } }
    }

    @Test fun cancelledAndSupersededLoginsCannotCommitIncludingLinkedLogin() {
        setup()
        Host("A").use { a -> Host("B").use { b ->
            login(a)
            b.block("/login")
            val attempt = Abs.beginLogin()
            var error: Throwable? = null
            val work = thread { error = runCatching { Abs.login(b.url, "other", "fixture", true, attempt) }.exceptionOrNull() }
            b.awaitRequest(); attempt.cancel(); b.release.countDown(); work.finished()
            assertTrue(error is StaleSession); assertEquals(a.url, Abs.server)
            a.block("/login")
            val linked = thread { error = runCatching { login(a, "late-linked", false) }.exceptionOrNull() }
            a.awaitRequest(); login(b); a.release.countDown(); linked.finished()
            assertTrue(error is StaleSession); assertTrue(Abs.accounts().isEmpty())
            assertEquals(b.url, Abs.server); assertNoCrossHost(a, b)
        } }
    }

    @Test fun lateRefreshReadFavoriteAndScheduledWorkCannotPolluteNewSession() {
        setup()
        Host("A").use { a -> Host("B").use { b ->
            a.expired = true; login(a)
            a.block("/auth/refresh")
            var error: Throwable? = null
            val refreshing = thread { error = runCatching { Abs.token() }.exceptionOrNull() }
            a.awaitRequest(); login(b); a.release.countDown(); refreshing.finished()
            assertTrue(error is StaleSession); assertEquals("B-access-same", Abs.token())
            a.expired = false; login(a)
            a.block("/late")
            val read = thread { error = runCatching { Abs.get("/late") }.exceptionOrNull() }
            a.awaitRequest(); val epoch = Abs.mediaEpoch; login(b); a.release.countDown(); read.finished()
            assertTrue(error is StaleSession); assertNull(Abs.cached("/late"))
            assertTrue(runCatching { Abs.sessionWork(epoch) { Abs.api("POST", "/stale") } }.exceptionOrNull() is StaleSession)
            assertTrue(runCatching { Abs.streamToken(Uri.parse(a.url + "/api/items/book/file/1"), Abs.mediaEpoch) }.exceptionOrNull() is StaleSession)
            assertTrue(b.requests.none { it.first == "/stale" })
            login(a); Abs.toggleFav(Card("book", "A", "")); a.block("/api/me/item/book/bookmark")
            val fav = thread { runCatching { Abs.pushFavs() } }
            a.awaitRequest(); login(b); Abs.toggleFav(Card("book", "B", "")); a.release.countDown(); fav.finished()
            assertTrue(JSONObject(Abs.p.getString("favq", "{}")!!).getBoolean("book"))
            assertNoCrossHost(a, b)
        } }
    }

    @Test fun unlinkDuringRefreshCannotResurrectAndRedirectCannotForwardCredentials() {
        setup()
        Host("A").use { a -> Host("B").use { b ->
            login(a); a.expired = true; login(a, "linked", false)
            a.block("/auth/refresh")
            val work = thread { runCatching { Abs.token("linked") } }
            a.awaitRequest(); Abs.unlink("linked"); a.release.countDown(); work.finished()
            assertFalse(Abs.accounts().contains("linked"))
            a.redirect = b.url + "/stolen"
            assertTrue(runCatching { Abs.api("GET", "/redirect") }.isFailure)
            assertTrue(b.requests.isEmpty())
            assertNoCrossHost(a, b)
        } }
    }
    @Test fun mediaTransportRejectsRedirectAndOldEpochButReadsFixtureBytes() {
        setup()
        Host("A").use { a -> Host("B").use { b ->
            login(a)
            val epoch = Abs.scope(playback = true).generation
            fun spec(url: String) = androidx.media3.datasource.DataSpec.Builder().setUri(url).setKey(epoch.toString()).build()
            val media = SessionDataSource()
            assertEquals(2L, media.open(spec(a.url + "/api/audio")))
            val bytes = ByteArray(2)
            assertEquals(2, media.read(bytes, 0, 2)); assertEquals("{}", String(bytes)); media.close()
            a.redirect = b.url + "/stolen"
            // Redirect endpoint is under the API prefix, like real media routes.
            a.server.createContext("/api/redirect") { x ->
                x.responseHeaders.add("Location", b.url + "/stolen")
                x.sendResponseHeaders(307, -1); x.close()
            }
            assertTrue(runCatching { media.open(spec(a.url + "/api/redirect")) }.exceptionOrNull() is HttpErr)
            login(b)
            assertTrue(runCatching { media.open(spec(a.url + "/api/audio")) }.exceptionOrNull() is StaleSession)
            assertTrue(b.requests.none { it.first == "/stolen" }); assertNoCrossHost(a, b)
        } }
    }

    @Test fun linkedCancelUnlinkAndSameHostLoginInvalidateOldAuthorization() {
        setup()
        Host("A").use { a ->
            login(a)
            for (cancel in listOf(true, false)) {
                a.block("/login")
                val attempt = Abs.beginLogin()
                val pending = thread { runCatching { Abs.login(a.url, "late", "fixture", false, attempt) } }
                a.awaitRequest()
                if (cancel) attempt.cancel() else Abs.unlink("late")
                a.release.countDown(); pending.finished()
                assertFalse(Abs.accounts().contains("late"))
            }
            login(a, "linked", false)
            val identity = Abs.p.getString("acct:same", null)
            login(a, "same", false) // linking yourself must not rotate the main session
            assertEquals(identity, Abs.p.getString("acct:same", null))
            val epoch = Abs.mediaEpoch
            Abs.setShares("book", setOf("linked")); Abs.toggleFav(Card("book", "A", ""))
            login(a)
            assertNotEquals(epoch, Abs.mediaEpoch)
            assertTrue(Abs.accounts().isEmpty()); assertTrue(Abs.favs().isEmpty()); assertTrue(Abs.shares("book").isEmpty())
            assertTrue(runCatching { Abs.streamToken(Uri.parse(a.url + "/api/audio"), epoch) }.exceptionOrNull() is StaleSession)
        }
    }

    @Test fun sameAccountJournalAndPlaybackSurviveReauthButReusedUsernameDoesNot() {
        setup()
        Host("A").use { host ->
            login(host)
            Abs.startProgress(false)
            val n = Now("book", null, "Book", "", listOf(Track("1", ".wav", 4, 100.0, 0.0)))
            val playing = Abs.scope(playback = true)
            val request = Abs.scope()
            Abs.bindPlayback(n, playing)
            Abs.push(n, 31.0, false)
            login(host)
            Abs.startProgress(false)
            assertEquals(playing, Abs.nowScope)
            assertNotEquals(request, Abs.scope())
            assertEquals(31.0, Abs.progressSync.local()[n.key]!!.getDouble("currentTime"), 0.0)
            host.idOverride = "different-immutable-account"
            login(host)
            Abs.startProgress(false)
            assertNull(Abs.nowScope)
            assertTrue(Abs.progressSync.local().isEmpty())
            assertNotEquals(playing, Abs.scope(playback = true))
        }
    }

}
