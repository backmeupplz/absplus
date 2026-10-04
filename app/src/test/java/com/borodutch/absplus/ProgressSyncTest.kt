package com.borodutch.absplus

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Real SharedPreferences + Abs auth/HTTP + replay against an isolated controlled server. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ProgressSyncTest {
    private lateinit var server: HttpServer
    private var time = 10_000L
    private val remote = ConcurrentHashMap<String, JSONObject>()
    private val patches = CopyOnWriteArrayList<String>()
    private val requests = CopyOnWriteArrayList<String>()
    @Volatile private var disconnected = false
    @Volatile private var failReadback = false
    private var creationTime = 500_000L
    @Volatile private var status = 0
    @Volatile private var refreshStatus = 200
    @Volatile private var rejectOldToken = false
    @Volatile private var refreshEntered: CountDownLatch? = null
    @Volatile private var releaseRefresh: CountDownLatch? = null
    @Volatile private var patchEntered: CountDownLatch? = null
    @Volatile private var releasePatch: CountDownLatch? = null
    @Volatile private var getEntered: CountDownLatch? = null
    @Volatile private var releaseGet: CountDownLatch? = null
    private val book = Now("book", null, "Book", "Author", listOf(Track("audio", ".mp3", 10, 100.0, 0.0)))
    private val episode = Now("podcast", "episode", "Episode", "Podcast", book.tracks)

    @Before fun setup() {
        Abs.init(RuntimeEnvironment.getApplication())
        Abs.openConnection = { if (disconnected) throw java.net.ConnectException("fixture offline") else JvmConnection(it) }
        Abs.progressSync.close()
        Abs.p.edit().clear().commit()
        Abs.now = null
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { x ->
            val name = x.requestHeaders.getFirst("Authorization")?.removePrefix("Bearer ")?.removeSuffix("-fresh") ?: "owner"
            val key = name + ":" + x.requestURI.path.removePrefix("/api/me/progress/")
            requests += x.requestMethod + " " + key
            var code = status.takeIf { it > 0 } ?: 200
            var body = "{}"
            if (x.requestURI.path == "/login") {
                val login = JSONObject(x.requestBody.bufferedReader().readText()).getString("username")
                body = JSONObject().put("user", JSONObject().put("username", login).put("accessToken", login).put("refreshToken", "fixture-refresh")).toString()
            } else if (x.requestURI.path == "/auth/refresh") {
                refreshEntered?.countDown(); releaseRefresh?.await(5, TimeUnit.SECONDS)
                code = refreshStatus
                body = JSONObject().put("user", JSONObject().put("username", name).put("accessToken", name + "-fresh").put("refreshToken", "fixture-refresh")).toString()
            } else if (rejectOldToken && !x.requestHeaders.getFirst("Authorization").orEmpty().endsWith("-fresh")) {
                code = 401
            } else if (code == 200 && x.requestURI.path.startsWith("/api/me/progress/")) {
                if (x.requestMethod == "GET") {
                    getEntered?.countDown(); releaseGet?.await(5, TimeUnit.SECONDS)
                    body = remote[key]?.toString() ?: "{}"
                    if (!remote.containsKey(key)) code = 404
                    else if (failReadback) code = 503
                } else {
                    val value = JSONObject(x.requestBody.bufferedReader().readText())
                    patchEntered?.countDown(); releasePatch?.await(5, TimeUnit.SECONDS)
                    // ABS sets server time on first creation, but accepts lastUpdate on updates.
                    if (!remote.containsKey(key)) value.put("lastUpdate", creationTime)
                    remote[key] = value
                    patches += key
                }
            }
            val bytes = body.toByteArray()
            x.sendResponseHeaders(code, bytes.size.toLong())
            x.responseBody.use { it.write(bytes) }
        }
        server.start()
        Abs.p.edit().putString("server", "http://127.0.0.1:" + server.address.port).putString("me", "owner")
            .putString("acct:owner", JSONObject().put("a", "owner").put("r", "fixture-refresh").toString())
            .putString("acct:linked", JSONObject().put("a", "linked").put("r", "fixture-refresh").toString()).commit()
        Abs.startProgress(false) { time }
        Abs.setShares(book.item, setOf("linked"))
        Abs.setShares(episode.item, setOf("linked"))
    }

    @After fun cleanup() {
        releasePatch?.countDown(); releaseGet?.countDown(); releaseRefresh?.countDown()
        Abs.progressSync.close()
        server.stop(0)
        Abs.p.edit().clear().commit()
        Abs.openConnection = { it.openConnection() as java.net.HttpURLConnection }
    }

    /** The JDK URLConnection rejects PATCH; Android supports it. Use JDK HttpClient only
     * for that lowest transport seam, keeping Abs HTTP/auth, disk journal and server real. */
    private class JvmConnection(url: java.net.URL) : java.net.HttpURLConnection(url) {
        private val output = java.io.ByteArrayOutputStream()
        private val headers = mutableMapOf<String, String>()
        private var response: java.net.http.HttpResponse<ByteArray>? = null
        override fun setRequestMethod(value: String) { method = value }
        override fun setRequestProperty(key: String, value: String) { headers[key] = value }
        override fun getOutputStream() = output
        private fun send(): java.net.http.HttpResponse<ByteArray> {
            response?.let { return it }
            val request = java.net.http.HttpRequest.newBuilder(url.toURI())
                .method(method, java.net.http.HttpRequest.BodyPublishers.ofByteArray(output.toByteArray()))
                .timeout(java.time.Duration.ofSeconds(10))
            headers.forEach { (key, value) -> request.header(key, value) }
            return java.net.http.HttpClient.newHttpClient().use {
                it.send(request.build(), java.net.http.HttpResponse.BodyHandlers.ofByteArray())
            }.also { response = it }
        }
        override fun getResponseCode() = send().statusCode()
        override fun getInputStream() = send().body().inputStream()
        override fun connect() { send() }
        override fun disconnect() {}
        override fun usingProxy() = false
    }

    private fun pending() = JSONObject(Abs.p.getString("progressJournal", "{}")!!).let { j ->
        j.keys().asSequence().map { j.getJSONObject(it) }.filter { it.optBoolean("dirty") }.toList()
    }
    private fun replay() = Abs.progressSync.replay()
    private fun tick() { time += 1 }

    /** Exercise the real service capture path used by periodic play, pause and STATE_ENDED. */
    private fun playbackEvent(n: Now, position: Double, finished: Boolean = false, playing: Boolean = false) {
        Abs.now = n
        val player = java.lang.reflect.Proxy.newProxyInstance(javaClass.classLoader, arrayOf(androidx.media3.common.Player::class.java)) { _, method, _ ->
            when (method.name) {
                "getCurrentMediaItem" -> androidx.media3.common.MediaItem.Builder().setMediaId(n.key + "#0").build()
                "getCurrentMediaItemIndex" -> 0
                "getPlaybackState" -> if (finished) androidx.media3.common.Player.STATE_ENDED else androidx.media3.common.Player.STATE_READY
                "getCurrentPosition" -> (position * 1000).toLong()
                else -> error("Unexpected player read: " + method.name)
            }
        } as androidx.media3.common.Player
        val service = org.robolectric.Robolectric.buildService(PlayerService::class.java).get()
        val listener = service.progressListener(player)
        if (finished) listener.onPlaybackStateChanged(androidx.media3.common.Player.STATE_ENDED)
        else listener.onIsPlayingChanged(playing)
    }

    @Test fun offlinePlayPauseFinishSurviveRestartAndReplayWithoutPlaying() {
        disconnected = true
        playbackEvent(book, 20.0); tick(); playbackEvent(book, 32.0)
        tick(); playbackEvent(episode, 100.0, true)
        replay()
        assertEquals(4, pending().size)
        assertEquals(1.0, Abs.pct(episode.key)!!, 0.0)
        assertFalse(Abs.p.getString("progressJournal", "")!!.contains("fixture-refresh"))
        // Reconstruct every replay object from persisted preferences (no title is played).
        Abs.now = null
        Abs.startProgress(false) { time }
        Abs.setMe(JSONObject().put("mediaProgress", JSONArray()).put("bookmarks", JSONArray()))
        assertEquals(1.0, Abs.pct(episode.key)!!, 0.0)
        assertEquals(0.0, Abs.positions(episode).first().time, 0.0)
        disconnected = false; time += 1_000
        replay()
        assertTrue(pending().isEmpty())
        assertEquals(setOf("owner:book", "linked:book", "owner:podcast/episode", "linked:podcast/episode"), patches.toSet())
        assertEquals(32.0, remote["owner:book"]!!.getDouble("currentTime"), 0.0)
        assertTrue(remote["linked:podcast/episode"]!!.getBoolean("isFinished"))
        assertEquals(0.0, Abs.positions(episode).first().time, 0.0)
    }

    @Test fun newerUpdateDuringInflightCreationIsNotAcknowledgedOrLost() {
        Abs.setShares(book.item, emptySet())
        Abs.push(book, 10.0, false)
        patchEntered = CountDownLatch(1); releasePatch = CountDownLatch(1)
        val worker = thread { replay() }
        assertTrue(patchEntered!!.await(5, TimeUnit.SECONDS))
        tick(); Abs.push(book, 70.0, false)
        releasePatch!!.countDown(); worker.join(5_000)
        assertFalse(worker.isAlive)
        assertEquals(1, pending().size)
        // Server timestamp on creation is later than our new event. Its matching payload
        // is recognized as our old write, not a conflict from another device.
        Abs.startProgress(false) { time }
        replay()
        assertTrue(pending().isEmpty())
        assertEquals(70.0, remote["owner:book"]!!.getDouble("currentTime"), 0.0)
        assertEquals(2, patches.size)
    }

    @Test fun remoteNewerWinsPerRecipientAndOlderReadCannotEraseFinished() {
        Abs.push(book, 100.0, true)
        remote["linked:book"] = JSONObject().put("currentTime", 8.0).put("lastUpdate", time + 500).put("progress", .08)
        Abs.setMe(JSONObject().put("mediaProgress", JSONArray().put(JSONObject().put("libraryItemId", "book").put("lastUpdate", 1).put("progress", .01))))
        assertEquals(1.0, Abs.pct(book.key)!!, 0.0)
        replay()
        assertEquals(listOf("owner:book"), patches.toList())
        assertEquals(8.0, remote["linked:book"]!!.getDouble("currentTime"), 0.0)
        tick(); Abs.push(book, 0.0, false)
        assertTrue(pending().all { it.getJSONObject("value").getBoolean("isFinished") })
    }

    @Test fun authRefreshRetriesOnceAndBackoffSurvivesRestartAndNewEvents() {
        Abs.setShares(book.item, emptySet())
        rejectOldToken = true; refreshStatus = 401
        Abs.push(book, 40.0, false)
        replay()
        assertEquals(1, requests.count { it.startsWith("POST") })
        assertEquals(time + 1_000, pending().single().getLong("next"))
        Abs.startProgress(false) { time }
        val count = requests.size
        tick(); Abs.push(book, 50.0, false); replay()
        assertEquals(count, requests.size)
        time += 999; replay()
        assertEquals(time + 2_000, pending().single().getLong("next"))
        refreshStatus = 200; time += 2_000; replay()
        assertTrue(pending().isEmpty())
        assertEquals(50.0, remote["owner:book"]!!.getDouble("currentTime"), 0.0)
    }

    @Test fun retriesAreBoundedAndNewSharesDoNotReceiveHistoricalEvents() {
        Abs.setShares(book.item, emptySet())
        status = 503; Abs.push(book, 20.0, false)
        repeat(14) {
            replay()
            val next = pending().single().getLong("next")
            assertTrue(next - time in 1_000..300_000)
            time = next
        }
        Abs.setShares(book.item, setOf("linked"))
        status = 0; replay()
        assertEquals(listOf("owner:book"), patches.toList())
    }

    @Test fun shareRemovalUnlinkAndLogoutPruneAndInvalidateInflightWork() {
        Abs.push(book, 22.0, false); Abs.push(episode, 25.0, false)
        Abs.setShares(book.item, emptySet())
        assertEquals(3, pending().size)
        Abs.unlink("linked")
        assertEquals(2, pending().size)
        getEntered = CountDownLatch(1); releaseGet = CountDownLatch(1)
        val worker = thread { replay() }
        assertTrue(getEntered!!.await(5, TimeUnit.SECONDS))
        Abs.logout()
        releaseGet!!.countDown(); worker.join(5_000)
        assertFalse(worker.isAlive)
        assertTrue(patches.isEmpty())
        assertTrue(pending().isEmpty())
        assertTrue(Abs.progress.isEmpty())
    }

    @Test fun passiveCompletionSurvivesButDeliberateOfflineRereadResumesAfterRestart() {
        disconnected = true
        for (n in listOf(book, episode)) {
            playbackEvent(n, 100.0, finished = true)
            tick(); playbackEvent(n, 0.0) // late pause, not a replay request
            Abs.startProgress(false) { time }
            tick(); playbackEvent(n, 0.0) // paused restoration
            assertEquals(1.0, Abs.pct(n.key)!!, 0.0)
            assertEquals(0.0, Abs.positions(n).first().time, 0.0)
            tick(); playbackEvent(n, 0.0, playing = true) // real service playing transition
            tick(); playbackEvent(n, 24.0) // pause after listening
            Abs.startProgress(false) { time }
            assertEquals(.24, Abs.pct(n.key)!!, 0.0)
            assertEquals(24.0, Abs.positions(n).first().time, 0.0)
            assertTrue(pending().filter { it.getString("key") == n.key }
                .all { !it.getJSONObject("value").getBoolean("isFinished") })
        }
        disconnected = false
        replay()
        assertTrue(pending().isEmpty())
        for (key in listOf("owner:book", "linked:book", "owner:podcast/episode", "linked:podcast/episode")) {
            assertEquals(24.0, remote[key]!!.getDouble("currentTime"), 0.0)
            assertFalse(remote[key]!!.optBoolean("isFinished"))
        }
    }

    @Test fun successfulCreationAckSurvivesLaterEventsAndRestartWithClockSkew() {
        for (n in listOf(book, episode)) {
            creationTime = time + 1_000
            Abs.setShares(n.item, emptySet())
            Abs.push(n, 10.0, false); replay()
            assertTrue(pending().isEmpty())
            time += 500
            Abs.push(n, 60.0, false)
            Abs.startProgress(false) { time }
            // Both foreground reads and replay must recognize this exact server acknowledgement.
            assertEquals(60.0, Abs.positions(n).first().time, 0.0)
            replay()
            assertTrue(pending().isEmpty())
            assertEquals(60.0, remote["owner:" + n.key]!!.getDouble("currentTime"), 0.0)
        }
        assertEquals(4, patches.size)
    }

    @Test fun unavailableReadbackRetainsAttemptUntilItsTimestampIsObserved() {
        Abs.setShares(book.item, emptySet())
        failReadback = true
        Abs.push(book, 10.0, false); replay()
        assertEquals(1, pending().size)
        tick(); Abs.push(book, 60.0, false)
        Abs.startProgress(false) { time }
        failReadback = false
        assertEquals(60.0, Abs.positions(book).first().time, 0.0)
        // The first observation pinned the timestamp. A later writer at the same
        // position is no longer accepted as that uncertain attempt.
        remote["owner:book"]!!.put("lastUpdate", 900_000L)
        assertEquals(10.0, Abs.positions(book).first().time, 0.0)
        assertTrue(pending().isEmpty())
        assertEquals(1, patches.size)
    }

    @Test fun successfulAckDoesNotMaskSamePayloadExternalWriteOnForegroundRead() {
        for (n in listOf(book, episode)) {
            Abs.setShares(n.item, emptySet())
            Abs.push(n, 10.0, false); replay()
            tick(); Abs.push(n, 60.0, false)
            Abs.startProgress(false) { time }
            remote["owner:" + n.key]!!.put("lastUpdate", time + 900_000)
            assertEquals(10.0, Abs.positions(n).first().time, 0.0)
            assertTrue(pending().isEmpty())
        }
        assertEquals(2, patches.size)
    }

    @Test fun acknowledgedPayloadDoesNotMaskALaterRemoteWriter() {
        Abs.setShares(book.item, emptySet())
        Abs.push(book, 10.0, false); replay()
        tick(); Abs.push(book, 60.0, false)
        // Another device returns to the old position, but with a newer timestamp.
        remote["owner:book"] = JSONObject().put("currentTime", 10.0).put("progress", .1).put("lastUpdate", time + 900_000)
        replay()
        assertEquals(1, patches.size)
        assertTrue(pending().isEmpty())
        assertEquals(.1, Abs.pct(book.key)!!, 0.0)
        assertEquals(10.0, Abs.positions(book).first().time, 0.0)
    }

    @Test fun newerEventDuringTokenRotationRetainsFreshCredentials() {
        Abs.setShares(book.item, emptySet())
        rejectOldToken = true
        refreshEntered = CountDownLatch(1); releaseRefresh = CountDownLatch(1)
        Abs.push(book, 10.0, false)
        val worker = thread { replay() }
        assertTrue(refreshEntered!!.await(5, TimeUnit.SECONDS))
        tick(); Abs.push(book, 50.0, false)
        releaseRefresh!!.countDown(); worker.join(5_000)
        assertFalse(worker.isAlive)
        assertEquals("owner-fresh", JSONObject(Abs.p.getString("acct:owner", "{}")!!).getString("a"))
        replay()
        assertTrue(pending().isEmpty())
        assertEquals(50.0, remote["owner:book"]!!.getDouble("currentTime"), 0.0)
    }

    @Test fun logoutDuringRefreshCannotResurrectAccountOrSendProgress() {
        Abs.setShares(book.item, emptySet())
        rejectOldToken = true
        refreshEntered = CountDownLatch(1); releaseRefresh = CountDownLatch(1)
        Abs.push(book, 20.0, false)
        val worker = thread { replay() }
        assertTrue(refreshEntered!!.await(5, TimeUnit.SECONDS))
        Abs.logout()
        releaseRefresh!!.countDown(); worker.join(5_000)
        assertFalse(worker.isAlive)
        assertFalse(Abs.p.contains("acct:owner"))
        assertTrue(patches.isEmpty())
        assertTrue(pending().isEmpty())
    }

    @Test fun ownerChangeCannotReplayOrReuseLinkedAuthorization() {
        Abs.push(book, 22.0, false)
        val endpoint = Abs.server
        status = 401
        assertTrue(runCatching { Abs.login(endpoint, "other", "fixture", true) }.isFailure)
        assertEquals("owner", Abs.me)
        assertEquals(2, pending().size)
        status = 0
        Abs.login(endpoint, "other", "fixture", true)
        Abs.startProgress(false) { time }
        assertTrue(pending().isEmpty())
        assertTrue(Abs.accounts().isEmpty())
        assertTrue(Abs.shares(book.item).isEmpty())
        Abs.push(book, 5.0, false); replay()
        assertEquals(listOf("other:book"), patches.toList())
    }

    @Test fun replayPinsUncertainAttemptBeforeFailedRetry() {
        Abs.setShares(book.item, emptySet())
        failReadback = true
        Abs.push(book, 10.0, false); replay()
        tick(); Abs.push(book, 60.0, false)
        time += 1000; failReadback = false
        var failed = false
        Abs.openConnection = { url ->
            if (url.path.startsWith("/api/me/progress/") && !failed) {
                // Let the preflight GET succeed; fail the immediately following PATCH
                // at the transport adapter without replacing the real replay implementation.
                object : java.net.HttpURLConnection(url) {
                    private val delegate = JvmConnection(url)
                    override fun setRequestMethod(v: String) { method = v; delegate.requestMethod = v }
                    override fun setRequestProperty(k: String, v: String) { delegate.setRequestProperty(k, v) }
                    override fun getOutputStream(): java.io.OutputStream {
                        if (method == "PATCH") { failed = true; throw java.net.ConnectException("before write") }
                        return delegate.outputStream
                    }
                    override fun getResponseCode() = delegate.responseCode
                    override fun getInputStream() = delegate.inputStream
                    override fun connect() {}
                    override fun disconnect() {}
                    override fun usingProxy() = false
                }
            } else JvmConnection(url)
        }
        replay()
        assertTrue(failed)
        val retry = pending().single()
        assertEquals(creationTime, retry.getJSONObject("ack").getLong("lastUpdate"))
        assertEquals(10.0, retry.getJSONObject("ack").getDouble("currentTime"), 0.0)
        assertEquals(60.0, retry.getJSONObject("sent").getDouble("currentTime"), 0.0)
        time += 2000
        Abs.startProgress(false) { time }
        replay()
        assertEquals("newer event must survive retry after uncertain first creation", 60.0, remote["owner:book"]!!.getDouble("currentTime"), 0.0)
    }

    @Test fun identicalRemotePayloadMustNotRegressTimestamp() {
        Abs.setShares(book.item, emptySet())
        Abs.push(book, 10.0, false)
        remote["owner:book"] = JSONObject().put("currentTime", 10.0).put("isFinished", false).put("lastUpdate", 900_000L)
        replay()
        assertEquals("already newer remote must not be rewritten", 900_000L, remote["owner:book"]!!.getLong("lastUpdate"))
        assertEquals(900_000L, Abs.progressSync.local()[book.key]!!.getLong("lastUpdate"))
        assertTrue(pending().isEmpty())
        assertTrue(patches.isEmpty())
    }

    @Test fun oldAccountGetCannotRepopulateCacheAfterAccountSwitch() = staleGetAfterLogout("other")

    @Test fun oldAccountGetCannotRepopulateCacheAfterSameAccountRelogin() = staleGetAfterLogout("owner")

    private fun staleGetAfterLogout(nextOwner: String) {
        val arrived = CountDownLatch(1)
        val release = CountDownLatch(1)
        val oldMe = JSONObject().put("mediaProgress", JSONArray().put(JSONObject().put("libraryItemId", "book").put("currentTime", 80.0).put("progress", .8).put("lastUpdate", 999999L))).put("bookmarks", JSONArray()).toString()
        Abs.openConnection = { url ->
            if (url.path == "/api/me") object : java.net.HttpURLConnection(url) {
                override fun setRequestMethod(v: String) { method = v }
                override fun getResponseCode(): Int { arrived.countDown(); release.await(5, TimeUnit.SECONDS); return 200 }
                override fun getInputStream() = oldMe.byteInputStream()
                override fun connect() {}
                override fun disconnect() {}
                override fun usingProxy() = false
            } else JvmConnection(url)
        }
        var failure: Throwable? = null
        val old = thread { failure = runCatching { Abs.get("/api/me") }.exceptionOrNull() }
        assertTrue(arrived.await(5, TimeUnit.SECONDS))
        Abs.logout()
        Abs.login("http://127.0.0.1:" + server.address.port, nextOwner, "fixture", true)
        Abs.startProgress(false) { time }
        release.countDown(); old.join(5000)
        assertFalse(old.isAlive)
        assertTrue("stale API response must be rejected", failure is Expired)
        assertNull("old account response must not survive in new account cache", Abs.cached("/api/me"))
    }

    @Test fun sameAccountReloginCannotAcceptAnOldTokenRefresh() {
        val arrived = CountDownLatch(1)
        val release = CountDownLatch(1)
        Abs.openConnection = { url ->
            if (url.path == "/auth/refresh") object : java.net.HttpURLConnection(url) {
                override fun setRequestMethod(v: String) { method = v }
                override fun getOutputStream() = java.io.ByteArrayOutputStream()
                override fun getResponseCode(): Int { arrived.countDown(); release.await(5, TimeUnit.SECONDS); return 200 }
                override fun getInputStream() = JSONObject().put("user", JSONObject().put("username", "owner")
                    .put("accessToken", "stale-refresh").put("refreshToken", "stale-refresh-token")).toString().byteInputStream()
                override fun connect() {}
                override fun disconnect() {}
                override fun usingProxy() = false
            } else JvmConnection(url)
        }
        val endpoint = Abs.server
        val credentials = Abs.p.getString("acct:owner", null)
        var failure: Throwable? = null
        val old = thread { failure = runCatching { Abs.token("owner", force = true) }.exceptionOrNull() }
        try {
            assertTrue(arrived.await(5, TimeUnit.SECONDS))
            Abs.logout()
            Abs.login(endpoint, "owner", "fixture", true)
            // The fixture deliberately issues identical credentials to expose identity-only fences.
            assertEquals(credentials, Abs.p.getString("acct:owner", null))
        } finally {
            release.countDown(); old.join(5000)
        }
        assertFalse(old.isAlive)
        assertTrue("refresh from the prior login must expire", failure is Expired)
        assertEquals(credentials, Abs.p.getString("acct:owner", null))
    }

    @Test fun automaticStartupDrainsPersistedQueueWithoutPlayback() {
        Abs.setShares(book.item, emptySet())
        Abs.push(book, 35.0, false)
        patchEntered = CountDownLatch(1)
        Abs.startProgress(true) { time }
        assertTrue(patchEntered!!.await(5, TimeUnit.SECONDS))
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (pending().isNotEmpty() && System.nanoTime() < deadline) Thread.sleep(10)
        assertTrue(pending().isEmpty())
        assertEquals(null, Abs.now)
    }
}
