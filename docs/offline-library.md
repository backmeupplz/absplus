# Offline Library eligibility (#30)

The iOS offline Library now passes disk-backed cards through the same `avail` /
`downloaded` predicate as other offline shelves (and Android Library). A book
needs a nonempty track list and all tracks complete; a podcast needs at least
one complete episode. The raw `downloads()` inventory is unchanged, so partial
books and short files remain visible/removable in Storage → Downloads.

Both platforms reject empty book track lists. Android additionally checks that
expected files exist: `File.length()` alone reports zero for a missing file, so
zero-size metadata must not make an absent track/episode appear complete.

Download changes still use `dlChanged()` / the existing observed revision; list
identity and scroll-position bindings are unchanged. No sorting, loading-state,
playback, queue, or release-version changes are included.

## Deterministic native checks

- Android `OfflineLibraryTest`: real Library grid, partial two-track book, complete
  book, podcast with one complete episode, short-only book/podcast, empty metadata,
  missing files with zero-size metadata, search and live completion/removal,
  retained return from Storage, and raw Storage visibility/removal.
- Android `NavigationTest.offlineDeletesRefreshOnReturnAndDownloadChangeWithoutLosingAnchor`:
  real RecyclerView identity/offset through live mutations and detail/Storage
  navigation. Its fixture now uses real complete-track metadata instead of an
  empty track list.
- iOS `UITests/OfflineLibrary`: real Library search/membership, live completion and
  removal, Storage swipe-to-remove, and visible-anchor retention through live
  mutation and detail return. DEBUG-only synthetic files, no user server/account.
- Existing `UITests/ListLifecycle` and `UITests/OfflineHome` remain regression gates.

Run `./gradlew testDebugUnitTest assembleDebug assembleRelease` and
`xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination
'platform=iOS Simulator,name=iPhone 17,OS=latest'
-only-testing:UITests/OfflineLibrary -only-testing:UITests/ListLifecycle
-only-testing:UITests/OfflineHome test`. CI selects the new iOS suite alongside
existing suites. Native fixtures/builds are source evidence, not proof that an
installed device or store release contains the fix.
