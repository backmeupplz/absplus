package com.borodutch.absplus

import com.sun.net.httpserver.HttpServer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class DownloadLockTest {
    @Test fun loginAndLogoutNeverWaitOnQueueOperationsHoldingDlBeforeMediaLock() {
        val c = RuntimeEnvironment.getApplication()
        Abs.init(c); Abs.logout()
        val host = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        host.createContext("/login") { x ->
            x.requestBody.close()
            val body = """{"user":{"username":"fixture","id":"owner","accessToken":"fixture"}}""".toByteArray()
            x.sendResponseHeaders(200, body.size.toLong()); x.responseBody.use { it.write(body) }
        }
        host.start()
        val url = "http://127.0.0.1:" + host.address.port
        val n = Now("lock-fixture", null, "Fixture", "", listOf(Track("one", ".mp3", 7, 60.0, 0.0)))
        try {
            for (login in listOf(false, true)) for (operation in listOf("add", "cancel", "load", "capture")) {
                Abs.login(url, "fixture", "fixture", true)
                Dl.add(c, n)
                if (operation == "load") Dl.clear()
                val holdingMedia = CountDownLatch(1)
                val commit = CountDownLatch(1)
                val entered = CountDownLatch(1)
                val failure = AtomicReference<Throwable?>()
                val mutation = thread(isDaemon = true) {
                    runCatching {
                        synchronized(Abs.mediaLock) {
                            holdingMedia.countDown()
                            check(commit.await(5, TimeUnit.SECONDS))
                            if (login) Abs.login(url, "fixture", "fixture", true) else Abs.logout()
                        }
                    }.exceptionOrNull()?.let { failure.set(it) }
                }
                assertTrue(holdingMedia.await(5, TimeUnit.SECONDS))
                var captured: Dl.Job? = null
                val queue = thread(isDaemon = true) {
                    entered.countDown()
                    runCatching {
                        when (operation) {
                            "add" -> { Dl.clear(); Dl.add(c, n) }
                            "cancel" -> Dl.cancel(n)
                            "load" -> Dl.load()
                            else -> captured = Dl.Job(n)
                        }
                    }.exceptionOrNull()?.let { failure.set(it) }
                }
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                while (queue.state != Thread.State.BLOCKED && queue.isAlive && System.nanoTime() < deadline) Thread.yield()
                val blocked = queue.state == Thread.State.BLOCKED
                // A monitor-only probe must complete while the queue waits for mediaLock.
                // The old add/cancel paths hold Dl here, deadlocking the account commit.
                val probe = thread(isDaemon = true) { synchronized(Dl) {} }
                probe.join(1000)
                val inverted = probe.isAlive
                // On inversion let the queue drain before attempting the account mutation,
                // so a regression reports an assertion instead of stranding the singleton locks.
                if (inverted) mutation.interrupt() else commit.countDown()
                mutation.join(5000); queue.join(5000); probe.join(1000)
                assertTrue("$operation must wait for account ownership", blocked)
                assertFalse("Dl held while waiting for mediaLock: $operation login=$login", inverted)
                assertFalse(mutation.isAlive); assertFalse(queue.isAlive)
                failure.get()?.let { throw AssertionError("$operation login=$login", it) }
                val job = captured ?: Dl.job(n.key)
                if (job != null) {
                    assertEquals(Abs.mediaEpoch, job.epoch)
                    assertEquals(Abs.server, job.server)
                    assertEquals(Abs.mediaDir, job.dir)
                }
                if (operation == "load") assertTrue(Dl.jobs.isEmpty()) // old queue cannot be adopted
            }
        } finally { host.stop(0); Dl.clear(); Abs.logout() }
    }
}
