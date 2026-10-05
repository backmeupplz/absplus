# Android loading audit — #25

Scope: existing Android surfaces in Main, Ui, Abs, PlayerService and Dl. No new navigation architecture, production accounts, server writes, simulator management or store release.

## Surface checklist

| Surface | Result | Behavior / evidence |
|---|---|---|
| Sign-in | Fixed | Immediate “Signing in…” disabled submit, captured input, page-owned completion, restored retry after failure. Real form fixture checks repeated taps and delayed 401. |
| Linked-account dialog | Fixed | Dialog remains open during request/error, “Linking…” and disabled submit, persistent error; Cancel available before request/after failure (in-flight credential transaction deliberately not dismissible). Loopback form fixture. |
| Home continue listening | Fixed | Cold loading distinct from successful empty; cached content stays during labeled update/error, inline retry. History remains local and immediate. Delayed real Home fixture. |
| Library discovery and library switching | Fixed | Library loading/error/retry and successful no-libraries copy; stale switched-page completion ignored. Selected library/ratio behavior retained. |
| Library titles and search | Fixed | Cold loading vs cached update vs loaded empty/no matches; retry refreshes same view/query/adapter; delayed results belong to retained page. Existing #21 500-title viewport tests plus new real navigation fixtures. |
| Offline library/download shelf | Fixed | One retained Library view changes between downloaded-only membership and online controls/data. Banner Retry re-fetches libraries, titles and progress without replacing search/grid; visible connectivity changes and Back recompute local membership. #21 deletion/anchor tests remain. |
| Series discovery / per-library series | Fixed | Empty copy hidden until all child lists have successful snapshots; independent child loading/error/retry. Cached shelf opens immediately. |
| Series shelf | Already correct | No asynchronous data request: receives loaded cards. Retained grid, stable-key anchor and download-change refresh untouched. |
| Favorites membership | Fixed | Cold loading does not flash empty; saved cards remain; membership failures are retryable. Hidden retained page owns results. |
| Favorites metadata | Fixed | Previously silent missing-title fetch failures now have loading/error/retry; nested loads inherit owner rather than the visible detail page. Real Favorites fixture and #21 delayed membership/metadata test. |
| Favorite toggle sync | Fixed | Immediate local favorite change retained; sync status, disabled duplicate toggle, terminal retry, existing durable favorite queue preserved. No new server operation. |
| Book / podcast details | Fixed | Initial loading/error/retry, cached update/error without blanking, malformed JSON handled, no-audio copy, RecyclerView state restored when metadata changes. Zero episodes remains explicit. |
| Play from history/continue/details/episodes | Fixed | Immediate audio loading, same-key duplicate coalescing, latest selection wins, navigation/stop invalidates completion; retry on failure/player-not-ready. Real delayed progress fixture checks repeated calls and Back. |
| Resume positions / player restore | Fixed | Known offline uses saved positions without waiting for unreachable remote accounts. Automatic restore cannot replace a newer user playback request. |
| Controller connection / Activity stop-start | Fixed | Late controller futures ignored after release; UI/download/connectivity tick is no longer blocked on controller success. |
| Mini-player and full player | Fixed | Buffering and playback error are explicit; play retries failed preparation. Media3 loader already performs stream/token work off main. |
| Artwork in grids/rows/details/player/downloads | Fixed | Immediate book placeholder, accessible loading/missing/error state; bounded connect/read timeout, finally-disconnect/temp cleanup, concurrent same-art deduplication, server-scoped cache and per-bind stale protection. Retry happens on rebind; missing 404 is remembered. Real Cover fixture. |
| Connectivity retry / automatic probe | Fixed | Single-flight probe, disabled “Connecting…” action; successful reconnect refreshes the mounted Library in place, including chips and title data. Connectivity changes update membership without rebuilding query/grid. Page-level Retry fetches failed content. |
| Download enqueue/progress/cancel | Already correct + fixed errors | Existing queued/waiting/determinate byte/ring states and resumable transfer retained. Foreground-service rejection and terminal HTTP/auth failures now remain visible with Retry instead of silently disappearing/stalling. Cancel checks before socket as well as during bytes/final rename. Real Downloads control fixture and range-transfer tests. |
| Settings/storage/download deletion/share choices | Already correct | Local data operations, no remote loading prerequisite. Linked-account request covered separately. Unlink removes local access immediately; server-session revocation remains best effort. |
| PlayerService stream setup / progress sync | Already correct for loading | Media3 loading thread resolves auth per request; progress sync runs off-main, saved local progress supplies offline fallback. No UI is held waiting on sync. |
| Abs cache / HTTP / token refresh | Fixed + existing | Existing network timeouts and synchronized token refresh retained. Malformed JSON no longer overwrites good cached JSON; responses from a changed account/server cannot write cache. UI delivery additionally checks account and page owner. |

## State and lifecycle contract

- Status feedback is page-owned and overlaid at the bottom, not inserted into the grid's layout; settling requests cannot shift #21 pixel anchors. Retained pages keep their status container and may finish behind details.
- Cold loads show a named indeterminate state, cached snapshots show “Updating…”, successful empty is screen-specific. Errors retain usable data and expose a scoped Retry (expired session exposes Sign in). No toast-only dead end for data reads.
- Requests are synchronous HTTP on background threads; navigation logically cancels delivery rather than trying to interrupt a socket. HTTP timeouts bound abandoned work. Repeated Retry is single-flight.
- Small existing on-disk JSON snapshots/local preference and download enumerations still render synchronously; slow remote work never runs on main. This patch does not introduce a database/cache architecture overhaul.

## Regression command

JDK 21 + Android SDK 36:

```sh
./gradlew testDebugUnitTest assembleDebug assembleRelease
```

LoadingTest adds 17 cases using real Main views, Material controls, RecyclerViews and navigation with latch-controlled loopback responses. They cover cold success/empty/failure/retry, cached refresh failure and recovery, malformed JSON, offline cached/uncached detail, retained Back/search, library switch, late detail failure, favorites metadata, duplicate/replaced playback, login/link controls, artwork rebinding/deduplication, and download queued/wait/error/cancel controls. NavigationTest retains all seven #21 regressions. DlTest covers resume/range and NowTest timeline mapping. Fixtures use disposable local application files and dummy credentials; no production services.

## Local verification

- 28 unit tests pass: 17 new loading view/navigation regressions, seven unchanged #21 retention regressions, three transfer tests and one timeline test.
- Debug and release builds use the existing JDK 21 / SDK 36 installation and offline Gradle dependency cache; no signing credentials were introduced.

## Evidence limits

Robolectric verifies view state, navigation, request counts, identity/offset and callback ownership; it does not prove real-device frame timing, predictive-back animation, audio hardware, notification permission/Android foreground-service quotas, TalkBack speech, or OS process death. Media3 buffering/error labels are code/build audited, not an end-to-end audio decode test. No physical-device screenshot or store publication is claimed.

## Independent review follow-up

Three reproduced review findings were corrected without changing the platform boundary:

- Failed downloads remain retryable entries, but the worker selects the next non-failed job. The bar, progress mode and notification use that same runnable selection. A real DlService/Dl.run loopback fixture returns 404 for the first job, delays then completes the second, and clicks Retry to successfully finish the first; it checks transferred file bytes and request order, not manually injected errors.
- Abs.get validates the consumer schema before committing JSON for every supported cache route (progress, continue listening, libraries, titles, series, compact and expanded item). Nested cards, progress IDs and expanded audio decode are checked without UI/preferences side effects. A real detail test starts from a valid snapshot, receives HTTP 200 {}, navigates Back and reopens with the fixture server stopped: saved detail and cache bytes survive. A route matrix also verifies wrong-schema cache preservation for every cached endpoint family.
- Cover binding always replaces both tag and request token before any early return, including blank item/server. A delayed image fixture binds two views to blank ID/server, restores the server, and waits for a third view's shared request to complete; neither blank placeholder can be overwritten.

The original 24 tests remain in the suite, including all seven #21 navigation regressions. These four added regressions close the specific review coverage gaps; the real-device/audio/OS limitations above remain unchanged.

## Independent regression sensitivity

At reviewed head `9c9807f`, swapping only `Main.kt` to the pre-fix `bf548df` version compiled and made `detailMalformedResponseIsRetryableAndOfflineCacheIsNotBlank` fail on the missing visible “Loading title…” assertion. Restoring the reviewed production file passed the identical test. No test edits or assertion weakening were used; the detached experiment checkout was restored clean.

## Review event866 recovery follow-up

- Mounted offline Library now retains one page, query and grid while reconnecting. The real banner Retry is single-flight; successful probing fetches online libraries, titles and progress. Heading/chips and downloaded-only membership change in place, both while visible and after real title detail → Back.
- Home Play validates expanded cached metadata and the selected playable audio before accepting it. Invalid JSON, wrong-schema objects and empty audio fall through to the server. Playback-specific validation runs before cache replacement; a failed server response remains retryable rather than trapping Retry on the same invalid cache.
- Two real Main Robolectric regressions add a 160-download deep viewport with a surviving stable key and -31 pixel intra-row offset, actual banner clicks, exact probe/data request counts, real detail navigation and both connectivity directions; Home uses actual continue-listening tile taps plus Retry for three invalid-cache variants and counts metadata/progress requests. No MediaController is attached: the playback test proves preparation reaches progress and preserves the explicit player-not-ready retry, not audio output.
- Integration merge `2df59f4` includes origin/main `073a0df`; narrow iOS resolutions retain both loading and download-retry selectors, cancellation checks and upstream durable download behavior. Pending #31 is not cherry-picked; its membership-authority flow requires integration if merged later.
- Final local verification (2026-10-04): 40 tests, zero failures/errors/skips (LoadingTest 19, NavigationTest 7, AccessibilityTest 6, DlTest 3, DownloadQueueTest 1, NowTest 1, OfflineHomeTest 2, OfflineLibraryTest 1). `testDebugUnitTest assembleDebug assembleRelease --offline --no-daemon --max-workers=2` passed with JDK 21 / SDK 36. Logs: `/tmp/abs25-b29e-recovery.log` (focused), `/tmp/abs25-b29e-full.log` (full build), `/tmp/abs25-b29e-final.log` (final production-tick fixture/full suite and builds).

### CI callback-order correction

The c477176 CI failure at `Chip.single()` was a fixture barrier race: server request counters and a rendered title grid did not prove the independent library-discovery callback had delivered its chips. The regression now deliberately holds discovery until titles render, asserts chips are still absent, releases discovery and waits for the real checked/visible chip. It also waits for progress and subsequent refresh status rows to settle before changing connectivity. All original identity, pixel-offset, membership, control and network-count assertions remain; no timing sleep was added. The discovery latch releases in `finally`, including early assertion failures, before fixture server/executor teardown.

Validation: the final teardown-safe fixture passed three forced executions (`--rerun`, logs `/tmp/abs25-b29e-barrier-focused-{7,8,9}.log`), following six successful development repetitions. The final full 40-test suite plus debug/release builds passed (`/tmp/abs25-b29e-barrier-final.log`); no production Android or iOS source changed in this correction.


## Authoritative library recovery integration (#31)

Merged main `6650ef7` into the loading work without changing iOS files. Library discovery now requires fresh membership before cached titles render or title HTTP requests start. The existing page-owned loading helper accepts an explicit freshness option and library request-epoch guard, retaining labeled loading/errors, single-flight Retry and account/page isolation. Back and reconnect refresh membership; revoked A→B resets query/grid with B's cover ratio, while an empty roster clears selection and titles. Superseded title status/retry owners are removed before discovery, so old requests cannot overwrite or retry into the new context.

All existing test cases remain. Loading fixtures now wait for the authoritative discovery callback instead of assuming parallel title requests; the explicit-switch fixture advertises both legal libraries. The mounted 160-download regression keeps every query, stable-key, pixel-offset, same-grid and exact request-count assertion, and now proves titles cannot start while discovery is gated. Two added integration cases cover mounted reconnect A→B→empty and failed fresh discovery with single-flight Retry and no cached-membership authorization. All nine upstream LibraryRecoveryTest cases remain intact.

Final integration verification: all 51 Android tests pass (20 Loading, 10 LibraryRecovery, 7 Navigation, 6 Accessibility and 8 existing transfer/offline/timeline cases), zero failures/errors/skips. `testDebugUnitTest assembleDebug assembleRelease --offline --no-daemon --max-workers=2` passed on the final tree. Log: `/tmp/abs25-b29e-integration-final.log`. iOS source/tests were untouched.
