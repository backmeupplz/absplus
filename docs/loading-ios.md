# iOS loading audit (#25)

Scope: existing SwiftUI surfaces in Screens/UI/App/Player/Abs. No store release,
new backend, real account, or server mutation is needed for the fixture suite.

## Surface checklist

| Surface | Disposition | Behavior |
| --- | --- | --- |
| Home continue listening + account progress | Fixed | Immediate labeled loading, local history retained, refresh indication, persistent error/retry; empty only after successful completion. |
| Library discovery and selected library | Fixed | Discovery failure retries discovery too; cached/retained grid stays mounted, explicit initial/refresh/empty/search/offline/error states. Context switches cancel prior work and discard old library cards. |
| Series discovery and per-library requests | Fixed | Initial/refresh/error/retry; no false empty after failure; surviving results retained, removed libraries pruned; offline rows filter unplayable shelves. |
| Favorites membership and metadata | Fixed | No premature empty; retained cards while refreshing; missing metadata has readable placeholder; only missing or previously failed metadata is fetched (not every populated favorite); failures surface retry; successful membership/metadata loads are cancellation checked. |
| Item details / book / podcast episodes | Fixed | Initial feedback rather than blank List, retained refresh, persistent failure and retry, cancellation on navigation away. Podcast episode empty count remains explicit in loaded metadata. |
| Shelf navigation | Already correct | Route owns existing cards, not an asynchronous fetch; native stable scroll targets retained. |
| Login | Fixed | Existing spinner/duplicate guard retained; persistent inline failure and input retention; cancellation prevents departed view login completion. |
| Link account | Fixed | Spinner, duplicate guard, inline failure, request cancelled on dismissal. Share selection/save itself is synchronous. |
| Offline reconnect | Fixed | One outstanding ping, connecting label/disabled retry, cancelled periodic task cannot start another ping. |
| Startup restore | Fixed | Shell paints first; cancelled startup does not resume downloads; delayed player restore cannot supersede a newer selection/logout. |
| Book/card/episode Play | Fixed | Screen-owned preparation task/token, duplicate suppression, latest selection wins after metadata/positions; Back or tab navigation cancels only preparation, never already-started playback. Home tile/context menu/recent button, book details and episode row/button use the same owner. |
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
buffering. Preparation and actual local AVQueuePlayer playback are covered by the
review follow-up below; remote buffering/background paths remain audited and
build-checked. No real media/network or
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


## Independent review follow-up: preparation after Back

The original fixture's empty tracks missed the preparation path. Unstructured Play
tasks could outlive a departed view and start its title after a delayed positions
response. HomeView and ItemView now own PlaybackRequest instances; every tile,
context menu, recent PlayButton, book button, episode button and row routes through
that owner. Disappearance cancels the task and invalidates only its matching player
preparation/choice token. Committed playback and the audio queue are not cleared or
paused. Player preparation APIs require an owner, so new callers cannot bypass it.
Same-owner duplicate taps are coalesced before the task starts; a late old completion
cannot clear a newer request.

The DEBUG --playback fixture generates a 120-second local silent PCM WAV and returns
nonempty book tracks and a podcast episode. Metadata and position requests have
independent gates. PlaybackPreparation exercises actual navigation and real
AVQueuePlayer: delayed metadata after leaving Home (tile/context menu/recent Play),
delayed positions after book/episode Back, double-tap request counts, repeated
opens, switching titles, no mini-player after cancellation, and continued playing
of the committed title when another preparation is cancelled.

Favorites now skips populated cards unless that specific metadata request previously
failed after rendering cache. A populated-Favorites UI fixture checks zero item
metadata requests across repeated tab visits.

The Home context-menu fixture exposed a native List/horizontal-shelf issue:
long-pressing the second title showed the first tile's Play action. Home now uses
a native vertical ScrollView/LazyVStack rather than hosting the whole shelf in one
List cell. Each tile owns its context Play/Details and preview directly. There is
no shared touch target or custom drag recognizer: horizontal scrolling and non-touch
menu ownership do not depend on a previous gesture. The five-card fixture swipes
to the fifth card, returns, and switches menus between the second and first tiles.
The existing second-title Play regression still checks that exact preparation and
cancels it by leaving Home. The same-screen switching test verifies only the latest
selected title starts. An additional right-click-after-touch test is runnable on
iPad. The assigned iPhone simulator rejects XCTest rightClick with “Pointer events
are not supported for this device”; that test explicitly skips on iPhone rather
than treating touch simulation as pointer proof. Physical VoiceOver, keyboard and
pointer activation remain unverified.

Direct playback metadata now validates Item before cache commit, just like screen
loads; invalid existing cached bytes fall through to a network request. The real
Home Play regression uses --invalid-item-response (HTTP 200 `{}` once, then a valid
Item), checks the failed response was not cached, taps Play again and verifies a
second metadata request, a valid cache, and actual local AVQueuePlayer playback.
--invalid-item-cache separately seeds old wrong-schema bytes and verifies Home Play
refetches and replaces them. Neither test opens Details to repair the cache first.


## Native shelf/cache follow-up verification (2026-10-04)

- Assigned iPhone simulator `81418EFF-A619-4374-9F0D-7C1B5D3E12B0`, isolated
  DerivedData `/tmp/abs25-native-derived`; Debug app and UI tests compiled.
- `/tmp/abs25-native-all.xcresult`: all 20 supported cases passed (LoadingLifecycle
  9, ListLifecycle 1, OfflineHome 1, PlaybackPreparation 9). The additional pointer
  probe failed only because this iPhone rejects pointer events. No product assertion
  failed in that run; the pointer test now explicitly skips unsupported iPhones.
- Final rebuilt focused suite `/tmp/abs25-native-final.xcresult`: **4 passed,
  1 explicit pointer skip, 0 failures**, TEST SUCCEEDED. Covers fifth-card swipe,
  second/first menu ownership and Details, second-title Play/cancellation, wrong-schema
  HTTP 200 then valid retry, and invalid existing-cache recovery.
- Release simulator build (arm64 + x86_64) succeeded;
  `/tmp/abs25-native-release.log`. No Android, CI or release configuration changes.
- Initial focused run had one test-query failure: ItemView renders its title in
  content, not the navigation bar. The corrected assertion checks the rendered
  first title and absence of the second title; shelf/menu assertions were retained.
- Physical-device VoiceOver, keyboard and pointer activation were unavailable.
