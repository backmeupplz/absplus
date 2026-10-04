# iOS loading audit (#25)

Scope: existing SwiftUI surfaces in Screens/UI/App/Player/Abs. No store release,
new backend, real account, or server mutation is needed for the fixture suite.

## Surface checklist

| Surface | Disposition | Behavior |
| --- | --- | --- |
| Home continue listening + account progress | Fixed | Immediate labeled loading, local history retained, refresh indication, persistent error/retry; empty only after successful completion. |
| Library discovery and selected library | Fixed | Discovery failure retries discovery too; cached/retained grid stays mounted, explicit initial/refresh/empty/search/offline/error states. Context switches cancel prior work and discard old library cards. |
| Series discovery and per-library requests | Fixed | Initial/refresh/error/retry; no false empty after failure; surviving results retained, removed libraries pruned; offline rows filter unplayable shelves. |
| Favorites membership and metadata | Fixed | No premature empty; retained cards while refreshing; missing metadata has readable placeholder; metadata failures surface retry; successful membership/metadata loads are cancellation checked. |
| Item details / book / podcast episodes | Fixed | Initial feedback rather than blank List, retained refresh, persistent failure and retry, cancellation on navigation away. Podcast episode empty count remains explicit in loaded metadata. |
| Shelf navigation | Already correct | Route owns existing cards, not an asynchronous fetch; native stable scroll targets retained. |
| Login | Fixed | Existing spinner/duplicate guard retained; persistent inline failure and input retention; cancellation prevents departed view login completion. |
| Link account | Fixed | Spinner, duplicate guard, inline failure, request cancelled on dismissal. Share selection/save itself is synchronous. |
| Offline reconnect | Fixed | One outstanding ping, connecting label/disabled retry, cancelled periodic task cannot start another ping. |
| Startup restore | Fixed | Shell paints first; cancelled startup does not resume downloads; delayed player restore cannot supersede a newer selection/logout. |
| Book/card/episode Play | Fixed | Local action spinner plus shared preparation identity, same-title deduplication, latest selection wins after async metadata/positions. |
| Mini/full player / queue | Fixed | Buffering feedback and persistent terminal error with Retry playback; queue generation checks after token and seek prevent stale queue completion. Empty audio is guarded. |
| Cover / BigCover | Fixed | Existing immediate placeholder, memory/disk cache, shared fetch and 404 fallback retained; cancelled old identity cannot paint a late image. Missing art is decorative fallback, not a blocking page error. |
| Download preparation | Fixed | Queue paints before token work; cancellation during token wait cannot restart removed queue; auth failure removes stuck waiting row so Download retries. |
| Download transfer / downloads screen / bar | Already correct | Byte progress, waiting spinner, cancellation, terminal transfer error toast and retry affordance; synchronous local listing and explicit no-downloads state. |
| Favorite write / progress sync | Already correct | Optimistic local state and persistent queued favorite changes; no blocking loading screen for background synchronization. |
| Settings / share selection / local removal | Already correct | Local synchronous operations; account login is covered above. |
| Shared JSON / token refresh | Fixed | Loads return errors to view state; invalid responses cannot overwrite a valid cache; cancellation checked before cache/render; stale server/account response discarded; logout cancels token refresh. Existing token-refresh coalescing retained. |
| Toast timeout | Fixed | Cancelled old timeout cannot erase a newer message. |

## Lifecycle invariants

View-owned Loading cancels its actual task on disappearance, including retries
started by buttons (not only SwiftUI .task). Same-surface duplicate requests are
ignored while busy. Cache rendering is synchronous before network suspension.
Feedback is an overlay: it does not replace/clear retained grids or change their
height. Library identity/search reset and native scrollPosition/scrollTargetLayout
from #21 remain unchanged. Library task/disappearance ownership sits outside the
scroll identity so a search/library/offline identity change cannot cancel the new
request. An empty library discovery also reaches a terminal empty state. Error is
never represented as successful empty.

## Reproduction / evidence

Use an isolated simulator because fixtures seed that simulator's app preferences,
keychain fixture tokens and JSON cache. DEBUG-only --loading-test intercepts only
abs-loading-fixture.invalid with delayed synthetic responses. --failure fails the
first request per endpoint, --empty returns successful empty collections, --no-libraries
returns empty discovery, --cached
seeds a title, --offline returns a transport failure. Production views/navigation
and actual URLSession decoding execute; there is no alternate test loading UI.
DEBUG-only Hold/Release controls stage responses before each initial-state assertion;
the wait is bounded to 60 seconds and cancellation stops a held response.

Run:

	xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus \
	  -destination 'platform=iOS Simulator,name=ABS25-Loading' \
	  -parallel-testing-enabled NO \
	  -only-testing:UITests/LoadingLifecycle -only-testing:UITests/ListLifecycle test

LoadingLifecycle covers delayed home/library/series/favorites/details, back before
details finish, repeated return, failure/retry, successful empty, cached failed
refresh, offline, library switching, login and link dismissal. ListLifecycle keeps
the #21 deep-scroll, changed-data, search, toolbar/gesture-back assertions.
The suite attaches a screenshot of the real Home initial-loading state.

Limitations: fixtures do not prove real-server compatibility, physical-device
VoiceOver, background OS download resumption, AirPlay, or AVFoundation network
buffering. These paths are audited and build-checked; no real media/network or
credential-dependent mutation is exercised.

## Local verification (2026-10-04, Xcode/iOS Simulator 27)

- Debug build-for-testing and Release simulator build succeeded.
- LoadingLifecycle: **9 tests, 0 failures**, `/tmp/absplus-25-ios-stable.xcresult`.
- The real Home initial-loading screenshot is a keep-always XCTest attachment
  named `Home initial loading` in that result bundle. It was exported and visually
  inspected at `/Users/borodutch/.openclaw/workspace/abs25-evidence/home-loading.png`
  (DEBUG response controls are visible; they do not ship in Release).
- Final binaries: **3 tests, 0 failures** (ListLifecycle retained scroll/search/
  changed-data/toolbar+gesture Back, delayed navigation, rapid library switching),
  `/tmp/absplus-25-ios-final-retention.xcresult`. This rechecks #21 after the
  loading/cancellation changes; it is not a helper-only test.
- Initial fixture attempts exposed/fixed accessibility-query assumptions, overlay
  controls covering tabs, fixture reinitialization, and the real library scroll-ID
  cancellation race. The passing suite uses bounded, explicit response gates.

