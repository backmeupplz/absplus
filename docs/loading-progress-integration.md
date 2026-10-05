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

## Final upstream skip integration

While the first full run was executing, upstream advanced to `1013039` (#28
whole-book skips). It was merged too, retaining its production skip changes and
both DEBUG fixture branches. The BookSkips selector was added to the offline lane;
CI now retains the exact union of all **11 suites**. No selectors were dropped.

The final merged source was rebuilt and fully retested:

- Android: **97 tests, zero failures/errors/skips**, across 13 suites;
  `testDebugUnitTest assembleDebug assembleRelease` passed.
  Log: `/tmp/abs25-integrate-final-android.log`.
- iOS: **35 passed, one expected iPhone pointer skip, zero failures**, all 11
  mapped suites; Release build also passed. Terminal test and release exit codes
  were both zero. Results: `/tmp/abs25-integrate-final-ios-full.xcresult` and
  `/tmp/abs25-integrate-final-ios-release.xcresult`, with matching logs. The Xcode
  diagnostic-collection timeout recurred after successful tests, without changing
  the successful terminal outcome.
- Read-only Astra/high integration review found no obvious merge defect;
  selector-union and whitespace checks passed.

All build/test processes were settled before the integration handoff. This is
local verification, not exact-head hosted CI or store deployment evidence.

## Transactional isolation integration

Integration of main `ac349e0` (#33, including the retained-download dependency)
is performed on top of `812ebed`. Native merge resolution preserves independent
page/preparation ownership and immutable host/account/session guards. Legacy
unscoped files remain quarantined; fixture seeding follows the authenticated
server/account media scope instead of bypassing production ownership checks.

CI retains the exact union of all **13 mapped suites** in three independent,
30-minute lanes: loading/playback, isolation/retained downloads, and
offline/progress/navigation. Fail-fast is disabled and full Android unit tests
remain enabled. `Tour` remains the existing credential-dependent unmapped suite.

Native validation uses `/tmp/abs25-isolation-android*` and
`/tmp/abs25-isolation-ios*`; iOS targets only simulator
`261196CA-6429-4460-80AD-E916F447F564`. Final terminal results follow below.

- Android final integration: **116 tests across 18 suites**, zero failures/errors/skips;
  full `testDebugUnitTest assembleDebug assembleRelease --offline --no-daemon
  --max-workers=2` exited 0 with JDK 21 / SDK 36. All test functions from both
  parents remain. Same-owner reauthentication now explicitly checks old preparation
  cleanup and fresh retry. Evidence: `/tmp/abs25-isolation-android-final.log`,
  `/tmp/abs25-isolation-android-summary.log`, `/tmp/abs25-isolation-android-xml/`
  and `/tmp/abs25-isolation-android-apks.sha256`.

- iOS: all **13 suites** ran in `/tmp/abs25-isolation-ios-full.xcresult`: 32
  passed, five fixture-integration failures, one expected iPhone pointer skip.
  Authenticated/scoped fixture paths, response sequencing and the loading API
  error-return contract were repaired without removing isolation or lifecycle
  assertions. `/tmp/abs25-isolation-ios-recovery.xcresult` then passed all 24
  supported cases (one expected pointer skip) across LoadingLifecycle, OfflineSeries,
  PlaybackPreparation, ProgressReplay, RetainedDownloads and SessionIsolation;
  exit 0. Combined suite coverage is **37 passed, one expected skip**, not a
  single green union invocation. Matching `.log` files preserve each outcome.
  Unsigned Release exited 0 (`/tmp/abs25-isolation-ios-release.xcresult` and `.log`).
- Independent integration review found no dropped selectors or ownership/lock
  regression, but identified a remote-playback auth-failure exit that could leave
  buffering without retry feedback. Its narrow correction and final evidence are
  recorded below.

### Final review correction

`Player.queue` now clears partial queue/buffering and exposes retryable terminal
feedback when streaming authentication fails. Existing queue/session ownership
checks fence the feedback; downloaded local audio remains playable. A new native
ProgressReplay case checks failed refresh, explicit Retry, real offline WAV playback
and a held old authentication failure that must not disturb newer playback/toast.

The final source passed all four affected suites (PlaybackPreparation, ProgressReplay,
RetainedDownloads, SessionIsolation): **14 passed, zero failures, one expected iPhone
pointer skip**, exit 0. Finalized bundle/log:
`/tmp/abs25-isolation-reviewfix-suites.xcresult` and matching `.log`. Unsigned Release
also exited 0 (`/tmp/abs25-isolation-reviewfix-release.xcresult` and `.log`). The added
case also passed alone in `/tmp/abs25-isolation-reviewfix-auth-fixed.xcresult`.
The focused fixture first needed a WAV byte-size correction; only its completed-test
diagnostic collector was stopped. The final four-suite run finalized normally.
Android was unchanged after its verified 116-test/build run. Across the full run,
recovery and final affected-suite rerun, all **38 supported iOS cases** have passing
evidence plus the one explicit pointer skip; no single final 13-suite green run is claimed.

Final upstream check (2026-10-04 21:40 PDT): `origin/main` remains `ac349e0`;
sibling PR #5 remains open, so no unlanded sibling delta was cherry-picked. The
already-landed retained-download dependency remains included through #33. CI exact
selector-union and staged/unstaged whitespace checks pass. All owned build/test
processes and helpers are settled; the assigned simulator is shut down. No push,
board update, hosted exact-head CI, signing, store publication or device claim.
