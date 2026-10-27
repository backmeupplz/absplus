package com.borodutch.absplus

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RatingPromptTest {
    private val day = 86_400_000L
    private val now = 1000 * day

    private fun due(first: Long = now - 3 * day, days: Int = 3, books: Int = 2, asked: Int = 0,
        last: Long = 0, lastVersion: Long = 0, version: Long = 7) =
        RatingPrompt.due(now, first, days, books, asked, last, lastVersion, version)

    @Test fun asksAfterTwoBooksOnThreeDaysOverThreeDays() {
        assertTrue(due())
        assertFalse(due(books = 1))
        assertFalse(due(days = 2))
        assertFalse(due(first = now - 3 * day + 1))
    }

    @Test fun asksASecondTimeOnlyAfter120DaysOnANewerVersionAndNeverAThird() {
        assertTrue(due(asked = 1, last = now - 120 * day, lastVersion = 6))
        assertFalse(due(asked = 1, last = now - 119 * day, lastVersion = 6))
        assertFalse(due(asked = 1, last = now - 120 * day, lastVersion = 7))
        assertFalse(due(asked = 2, last = now - 400 * day, lastVersion = 1))
    }
}
