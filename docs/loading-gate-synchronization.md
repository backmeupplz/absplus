# Loading fixture gate synchronization (#36)

## Second hosted failure is not the Favorites transition

Checks run 37290251359, loading job 111698723625, artifact 11337227673
fails the first Home Retry wait, before any tab navigation. The final hierarchy
still selects Home and eventually displays Retry with “The request timed out.”
The app log reports `NSURLErrorTimedOut` (-1001) for
`/api/me/items-in-progress` at 09:37:49.452596 UTC.

The release control receives a synthesized 50ms down/up inside its AX frame
(at 142,117.667; frame 78.7,111,126.7,13.3). The recording shows it highlighted
after delivery, but the old fixture exposes no gate acknowledgment. Touch
delivery is not proof that the action changed the gate. Nor does this evidence
prove why UIKit/SwiftUI did not finish the interaction promptly.

The release synthesis starts at test time 22.34s and finishes at 24.92s.
Retry is awaited from 25.02s through 40.38s; the failure hierarchy at 44.20s
contains Retry. Production URLRequests have a 20s timeout whereas the fixture
can hold responses for 60s. A delayed or uncommitted gate interaction therefore
can turn a planned HTTP 503 into a transport timeout. The historic artifact
cannot distinguish gate non-transition from delayed response delivery.

## Minimal test-only repair

DEBUG-only Release/Hold controls now expose `released`/`held` accessibility
values set by the same action that writes the protocol gate. LoadingLifecycle
sends one deliberate 100ms touch and requires the corresponding acknowledgment
within four seconds before checking the existing loading/error/content state.
This adds a diagnostic boundary, not a substitute for the real URLSession and
production-view assertions. No retry, timeout increase, automatic release,
programmatic navigation or production change is introduced. A gate failure
now fails at the control rather than being misattributed to Home/Favorites.

Original loading, error, retry, navigation, retained-content and scoped-media
acceptance remains intact. The native request timeout, 60s fixture bound and
2.5s response delay are unchanged. This instrumentation plus deliberate input
needs a fresh hosted run; local iOS 27 success cannot establish an iOS 26.5
runner-specific fix.

## Independent offline-progress launch failures

Job 111698723598, artifact 11336848444 has two Accessibility failures at
`app.launch()`, before product interaction. The first launch reply arrives at
09:34:30.648 UTC, after XCTest’s 60s waiter expires at 09:34:23.701. Its late
launch creates PID 6712 at 09:34:36.907. The second launch creates PID 6730 at
09:34:38.996; PID 6712 is already dead at 09:34:38.997. At 09:34:39.954 a
delayed state callback reports the old PID; XCTest then requests its background
assertion against dead PID 6712. The third launch (6786) and remaining tests
succeed. This is a demonstrated stale-process orchestration failure following
a delayed launch reply, independent of LoadingFixture. The reason for the
first launch delay remains unknown. No Accessibility, startup, CI or launch
timeouts were changed to hide it.

## Verification

- Recovered interrupted instrumentation-only probe: 1 passed, 0 failures,
  `/tmp/abs36-second-probe-v2.xcresult`; no rerun was needed to recover it.
- Final deliberate input: delayed navigation and failure/retry each repeated
  three times, **6 passed, 0 failures**, `/tmp/abs36-resume-focused.xcresult`.
- Negative control: temporarily removing the Release action fails specifically
  at the gate acknowledgment (`LoadingLifecycle.swift:23`), with AX value
  `held` and Home still loading. It never reaches the downstream Retry wait.
  `/tmp/abs36-resume-negative.xcresult`, expected xcodebuild exit 65. The exact
  fixture source was restored before the final suite build.
- Final rebuilt union of all **13 CI-mapped suites: 38 passed, one existing
  unsupported-iPhone pointer skip, zero failures**,
  `/tmp/abs36-resume-full.xcresult` and matching `.log`; terminal exit 0 and
  `TEST SUCCEEDED`. Includes all Accessibility cases, loading/playback, offline
  navigation/progress, retained downloads and transactional session isolation.
  Tests took 1,076s; Xcode then exhausted its existing 600s simulator diagnostic
  collection bound before successfully finalizing the bundle. No test or
  collector process was killed to obtain this result.
- Unsigned Release simulator build succeeded,
  `/tmp/abs36-resume-release-v2.xcresult` and `/tmp/abs36-resume-release.log`.
- Source checks verify unchanged acceptance method bodies, existing timeouts,
  protocol behavior, production loading/transport, and the exact CI selector
  union. Android and CI configuration are untouched.

Local environment: Xcode 27 / iOS Simulator 27.0, owned iPhone 17 simulator
`68437655-B527-48E2-890E-D0EB2A5CA066`. No real accounts, external media,
physical-device coverage or hosted exact-head green result is claimed.
