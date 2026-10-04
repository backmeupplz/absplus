# Title-list navigation regression

Android (JDK 21, Android SDK 36):

```sh
./gradlew testDebugUnitTest assembleDebug assembleRelease
```

`LibraryRecoveryTest` uses a loopback HTTP fixture and the real Activity/RecyclerView to cover stale cached membership, removed/revoked selection recovery on Back, empty membership, explicit switching, delayed old membership/items, and recovery while details are open. Online Library requests validate fresh `/api/libraries` membership before requesting selected-library items; same-library Back retains its query and viewport, while automatic/manual library changes reset both. No-library responses clear the stored selection and show “No libraries available.” Offline downloads retain their existing behavior.

`NavigationTest` exercises the real Activity navigation and RecyclerView layout with 500 titles, a nonzero pixel offset, repeated toolbar/system-dispatcher Back, deferred layout, search retention, and explicit context invalidation. No real server or playback is needed. Android gesture Back goes through the same registered OnBackPressedDispatcher callback; physical predictive-back animation is not simulated by Robolectric.

iOS (Xcode 27, an installed iPhone simulator):

```sh
xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus \
  -destination "platform=iOS Simulator,name=iPhone 18 Pro" \
  -only-testing:UITests/ListLifecycle test
```

Use a disposable simulator: the debug-only `--list-lifecycle-test` fixture seeds fixture login/preferences in that simulator. It intercepts only its `.invalid` fixture host, provides 500 titles and delayed list responses, and opens the real LibraryView/NavigationStack/ItemView. The test checks title identity and exact screen Y after toolbar and edge-swipe Back, then switches libraries and verifies the new list starts at the top. Release builds omit the fixture.

Neither app currently implements paginated title fetching or a user-selectable sort; both fetch a title-sorted result set in one request. The deep-list cases cover later loaded content without introducing a new pagination feature. State is navigation-lifetime only, not persisted across app restarts.

## Verified locally

Library recovery (#31): all 26 Android unit tests and debug/release APK builds passed, including 7 new recovery tests and all 7 retained-navigation regressions. Negative control against the pre-fix Android source fails the fresh-membership gate assertion (500 stale A titles shown instead of 0 before membership completes). Existing iOS ListLifecycle, Accessibility and OfflineHome fixtures passed (5 tests) on a dedicated iPhone 18 Pro / iOS 27 simulator; no iOS source changes or personal devices/accounts were used.

- Android: eleven unit tests (seven navigation regressions) and debug/release APK builds.
- iOS: Xcode 27 simulator debug/release builds; lifecycle UI test checks repeated round trips including edge swipe, search, delayed responses/cache eviction, insertions, deletions and reordering ahead of the viewport, and library reset.
- Review negative control: removing the native iOS scroll-target fix makes the changed-data return lose the visible title; the updated fix passes the same test.
- Negative control: original Android navigation fails the retained viewport/search tests. With the original iOS LibraryView, the new-library top assertion fails (the old viewport is reused). Warm-cache same-list round trips happened to pass on iOS 27; the unconditional empty/reload is still removed to avoid clamping when data is asynchronous.

Review regressions also cover offline deletion via Settings → Downloads → Back twice, download-change refresh, and delayed Favorites membership plus metadata responses while details are open. The cached Series → shelf regression opens real title details, confirms Remove download, and returns to the retained shelf; it checks removal, surviving title identity and pixel offset, then deletion and insertion ahead of the viewport through download-change callbacks (including multiple callbacks before layout). Android anchors use the bound card identity so multiple updates before the next layout cannot mistake an old adapter index for a new item. iOS uses native stable scroll targets without a fixed anchor, preserving the existing intra-item offset.

PR checks run Android tests/build and the isolated iOS lifecycle test on macOS 26 (runner image includes iOS 26.5, compatible with the app’s iOS 26.1 deployment target). No signing secrets or store release workflows are used.
