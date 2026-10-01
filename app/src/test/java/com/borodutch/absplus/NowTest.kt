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
}
