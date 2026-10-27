package com.borodutch.absplus

import android.app.Activity
import android.content.Context
import java.time.LocalDate

/** Asks for a store rating with the store's own card and nothing of ours in front of it (#205). The value moment is a
 * finished book: once 2 are finished and the app has been opened on 3 different days, the first at least 3 days ago,
 * the next book to finish asks when playback has stopped and the user is back in the app. At most twice per install,
 * the second time 120+ days later on a newer version: no store says whether the user rated, so the cap is how
 * "not now" is respected. Nothing leaves the device, and the F-Droid build's [storeReview] does nothing. */
object RatingPrompt {
    private const val DAY = 86_400_000L
    // In memory only: a book that ended before the app was killed doesn't ask on the next launch
    private var pending = false

    fun due(now: Long, first: Long, days: Int, books: Int, asked: Int, last: Long, lastVersion: Long, version: Long) =
        days >= 3 && now - first >= 3 * DAY && books >= 2 &&
            (asked == 0 || asked == 1 && now - last >= 120 * DAY && version > lastVersion)

    private fun prefs(c: Context) = c.getSharedPreferences("rating", 0)

    /** The app is on screen: counts the day */
    fun used(c: Context) {
        val p = prefs(c)
        val today = LocalDate.now().toEpochDay()
        if (p.getLong("day", -1) == today) return
        val e = p.edit().putLong("day", today).putInt("days", p.getInt("days", 0) + 1)
        if (!p.contains("first")) e.putLong("first", System.currentTimeMillis())
        e.apply()
    }

    /** A book played to its end */
    fun finished(c: Context) {
        prefs(c).run { edit().putInt("books", getInt("books", 0) + 1).apply() }
        pending = true
    }

    /** Called while the user is in the app with playback stopped: asks once after a book finished, if [due] */
    fun ask(a: Activity) {
        if (!pending) return
        pending = false
        val p = prefs(a)
        val now = System.currentTimeMillis()
        val version = a.packageManager.getPackageInfo(a.packageName, 0).longVersionCode
        val asked = p.getInt("asked", 0)
        if (!due(now, p.getLong("first", now), p.getInt("days", 0), p.getInt("books", 0), asked, p.getLong("last", 0), p.getLong("version", 0), version)) return
        p.edit().putInt("asked", asked + 1).putLong("last", now).putLong("version", version).apply()
        storeReview(a)
    }
}
