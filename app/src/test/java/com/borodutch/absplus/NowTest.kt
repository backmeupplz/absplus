package com.borodutch.absplus

import org.junit.Assert.assertEquals
import org.junit.Test

class NowTest {
    private val n = Now("i", null, "t", "a", listOf(Track("1", ".mp3", 0, 100.0, 0.0), Track("2", ".mp3", 0, 50.0, 100.0)))

    @Test fun mapsBookTimeToTrackAndOffset() {
        assertEquals(150.0, n.duration, 0.0)
        assertEquals(0 to 0L, n.at(0.0))
        assertEquals(0 to 99_500L, n.at(99.5))
        assertEquals(1 to 0L, n.at(100.0))
        assertEquals(1 to 25_000L, n.at(125.0))
    }

    @Test fun nextEpisodeIsNewerFirstThenNewestOlder() {
        val unfinished = setOf(0, 1, 3, 5)
        assertEquals(3, Abs.nextIndex(6, 2) { it in unfinished }) // the next newer one
        assertEquals(5, Abs.nextIndex(6, 4) { it in unfinished })
        assertEquals(3, Abs.nextIndex(6, 5) { it in unfinished - 5 }) // newest finished: newest older unfinished
        assertEquals(null, Abs.nextIndex(1, 0) { true })
    }
}
