# Loading/progress integration (#25)

Merged upstream `4e6dd6d` (offline progress #34 and sibling-download removal #27)
into reviewed loading head `c673835`. Account-generation guards compose with
page/screen request ownership, loading/retry state, validated cache writes, offline
journal resume positions and playback preparation cancellation. Cancelling an old
owner cannot cancel a newer request, replay a stale resume choice or stop committed
playback. All upstream fixture selectors remain available.

Integration regressions add Android same-account reauthentication/loading,
same-title cross-account preparation, and offline journal/navigation cancellation;
iOS adds held loading/position cancellation, stale and superseded resume owners,
same-account reauthentication, committed playback and linked episode replay.

## Local verification (2026-10-04)

- Android: **93 tests passed**, zero failures/errors/skips; Debug and Release APK
  builds passed (JDK 21.0.12.1 / SDK 36). Full available unit-test task:
  `testDebugUnitTest`. Logs: `/tmp/abs25-integrate-android-verified.log` and
  `/tmp/abs25-integrate-android-summary.log`.
- iOS simulator `261196CA-6429-4460-80AD-E916F447F564`: all ten mapped suites,
  **32 passed, one expected unsupported-iPhone pointer skip, zero failures**;
  Release build passed. Result bundles: `/tmp/abs25-integrate-ios-full.xcresult`
  and `/tmp/abs25-integrate-ios-release.xcresult` (matching `.log` files).
  Xcode's diagnostic collection timed out after its bounded 600 seconds, but the
  test process completed with exit 0 and TEST SUCCEEDED; tests themselves took
  1,011 seconds. No product assertion failed.
- CI preserves the exact union of the ten parent selectors in two independent
  30-minute lanes (loading/playback and offline/progress/navigation), with
  fail-fast disabled. No tests were removed or weakened. Tour remains the existing
  credential-dependent, unmapped real-server suite; physical-device behavior is
  not claimed.

All build/test processes were settled before the integration handoff. This is
local verification, not exact-head hosted CI or store deployment evidence.
