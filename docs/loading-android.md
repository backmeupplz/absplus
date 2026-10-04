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
| Offline library/download shelf | Already correct, clarified | Local download list and downloaded-only filtering retained; explicit no-download/no-match copy added. No networking gate on local content. #21 deletion/anchor tests remain. |
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
| Connectivity retry / automatic probe | Fixed | Single-flight probe, disabled “Connecting…” action; connectivity change no longer rebuilds current list and destroys search/viewport. Page-level Retry fetches failed content. |
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

LoadingTest adds 13 cases using real Main views, Material controls, RecyclerViews and navigation with latch-controlled loopback responses. They cover cold success/empty/failure/retry, cached refresh failure and recovery, malformed JSON, offline cached/uncached detail, retained Back/search, library switch, late detail failure, favorites metadata, duplicate/replaced playback, login/link controls, artwork rebinding/deduplication, and download queued/wait/error/cancel controls. NavigationTest retains all seven #21 regressions. DlTest covers resume/range and NowTest timeline mapping. Fixtures use disposable local application files and dummy credentials; no production services.

## Local verification

- 24 unit tests pass: 13 new loading view/navigation regressions, seven unchanged #21 retention regressions, three transfer tests and one timeline test.
- Debug and release builds use the existing JDK 21 / SDK 36 installation and offline Gradle dependency cache; no signing credentials were introduced.

## Evidence limits

Robolectric verifies view state, navigation, request counts, identity/offset and callback ownership; it does not prove real-device frame timing, predictive-back animation, audio hardware, notification permission/Android foreground-service quotas, TalkBack speech, or OS process death. Media3 buffering/error labels are code/build audited, not an end-to-end audio decode test. No physical-device screenshot or store publication is claimed.
