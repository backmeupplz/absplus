package com.borodutch.absplus

import android.app.Activity
import com.google.android.play.core.review.ReviewManagerFactory

/** Google Play's in-app review card (Play build only); Play decides whether it actually shows */
fun storeReview(a: Activity) {
    val m = ReviewManagerFactory.create(a)
    m.requestReviewFlow().addOnSuccessListener { if (!a.isDestroyed) m.launchReviewFlow(a, it) }
}
