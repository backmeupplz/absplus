# Title-list navigation regression

Android (JDK 21, Android SDK 36):

```sh
./gradlew testDebugUnitTest assembleDebug
```

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

- Android: ten unit tests (six navigation regressions) and debug/release APK builds.
- iOS: Xcode 27 simulator debug/release builds; lifecycle UI test checks repeated round trips including edge swipe, search, delayed responses/cache eviction, insertions, deletions and reordering ahead of the viewport, and library reset.
- Review negative control: removing the native iOS scroll-target fix makes the changed-data return lose the visible title; the updated fix passes the same test.
- Negative control: original Android navigation fails the retained viewport/search tests. With the original iOS LibraryView, the new-library top assertion fails (the old viewport is reused). Warm-cache same-list round trips happened to pass on iOS 27; the unconditional empty/reload is still removed to avoid clamping when data is asynchronous.

Review regressions also cover offline deletion via Settings → Downloads → Back twice, download-change refresh, and delayed Favorites membership plus metadata responses while details are open. Android anchors use the bound card identity so multiple updates before the next layout cannot mistake an old adapter index for a new item. iOS uses native stable scroll targets without a fixed anchor, preserving the existing intra-item offset.

PR checks run Android tests/build and the isolated iOS lifecycle test on macOS 26 (runner image includes iOS 26.5, compatible with the app’s iOS 26.1 deployment target). No signing secrets or store release workflows are used.
