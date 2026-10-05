# Downloaded Library anchor and retained errors

## Hosted failure

Run `37269568700`, `iOS (offline-progress)`, failed only
`OfflineLibrary.testLiveMutationAndDetailReturnKeepVisibleAnchor` at the
post-return pixel assertion (`519.333` versus `230.333`, tolerance `3`).
The source head was `7a702092c5d63f6eb7653b26a2a02155b95dff9e`.

Video and native AX diagnostics from artifact `11328348543` show that:

1. The selected title was initially in the left column at `(16, 230.333)`,
   next to the retained Offline error card.
2. Completing another download reflowed that title into the middle column
   at `(143.333, 230.333)`, behind the error card. Its vertical assertion passed.
3. `XCUIElement.tap()` then found the title unhittable (`{-1, -1}`) and
   automatically scrolled it to `y = 324.333` **before** opening details.
4. The return assertion compared against the now-invalid pre-tap baseline.

This is not evidence of sampling before the return animation settled. The
viewport had already moved during the synthesized tap. The existing test
also passes locally depending on which row the inertial swipes expose.

## Root cause and correction

A retained-error `safeAreaInset` moves the initial content inset, but a
`ScrollView` can still draw and hit-test scrolled rows under that inset.
Thus the existing loading contract—failed refreshes leave retained titles
uncovered and usable—did not hold after scrolling and live grid reflow.
This directly interfered with the navigation regression gate; no progress
replay, download membership or scroll-restoration algorithm needed changing.

Keep the error as a real sibling above the content in an always-present
`VStack`. The content remains in the same structural slot as error state
changes. Initial/refresh loading and empty feedback retain their overlay,
and the loading/cancellation, account, credential and transport guards are
unchanged.

The regression additionally requires the Retry button to be above the
actual scroll viewport, checks target hittability after insertion, and taps
the observed point rather than allowing XCTest to auto-scroll an obscured
element. It still performs real detail navigation, the live undo while
details are open, and the original immediate 3-point return assertion; a
second settled assertion is additive. A screenshot records the live-update
state. No retries, offset resets, tolerance relaxation or suite removal.

## Sensitivity and validation

On an owned iPhone 17 simulator / iOS 27, restoring only the old production
`Loading.swift` makes the strengthened test fail deterministically:
Retry bottom `252.333` exceeds ScrollView top `0`. With the correction the
ScrollView starts at `284.333`, and the focused navigation test passes.
The release simulator build also succeeds. Further repeated and related
suite evidence is recorded in the PR handoff; hosted CI and independent
review remain separate gates. Physical-device navigation is not proven.
