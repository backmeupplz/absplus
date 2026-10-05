# Selected download removal (#27)

The original iOS unconditional recursive parent deletion was already corrected by #32 / PR #9. Selected removal now uses POSIX `rmdir` for its shared item folder: it can remove only an empty directory, without an enumerate-then-recursive-delete window. `removeAll` deliberately retains recursive item deletion. Android already uses nonrecursive `File.delete()` for the parent.

## Regression coverage

- iOS `UITests/DownloadRemoval` launches a DEBUG-only synthetic fixture on a disposable simulator. It creates two saved podcast episodes A/B, partial queued C/D, and another item. Production `Abs.remove(A)` preserves B/C/D; cancelling C clears only C files, resume state, retry state and transfer identity. A late delegate completion cannot resurrect C. D retains bytes, queue, retry deadline and transfer ownership.
- The test terminates/relaunches the app, reloads durable metadata/queue and validates B still resolves to its local URL offline. Restoring the downloader and queue preserves D. Explicit `removeAll` deletes all files/partials/state for the podcast but not the other item; selected removal of the last file removes its empty folder.
- Android `DownloadRemovalTest` covers production selected removal, queue cancellation, durable reload/offline URI and deliberate remove-all with sibling/other-item preservation.

Run Android with `./gradlew testDebugUnitTest assembleDebug assembleRelease`. Run iOS with `xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:UITests/DownloadRemoval test`. CI includes the new iOS suite alongside all existing suites.

The fixtures use synthetic bytes, not playable audio or a personal library. iOS proves real process relaunch and production delegate state handling with controlled task doubles; Android uses Robolectric and persisted queue reload, not a physical-device process restart. Neither proves installed/store delivery, physical playback, or system background-transfer behavior.
