# ABS+

A small, fast Android and iOS player for your own [Audiobookshelf](https://www.audiobookshelf.org) server. Free, no ads, no analytics.

- Website: https://absplus.app (source in `docs/`, served by GitHub Pages)
- Google Play: https://play.google.com/store/apps/details?id=com.borodutch.absplus
- App Store: https://apps.apple.com/app/id6818353284
- APK: [latest release](https://github.com/backmeupplz/absplus/releases/latest)

## Build

JDK 21 and the Android SDK:

```sh
./gradlew assembleRelease
```

Without a `keystore.properties`, release builds come out unsigned, which is how F-Droid builds them.

## Releasing

Bump `versionCode` and `versionName` in `app/build.gradle.kts` and add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` (one or two plain sentences, with no mention of Android or iPhone: Google Play, the App Store and F-Droid all show them). Merge, then publish the release on git.borodutch.com:

```sh
tea release create --repo backmeupplz/absplus --tag vX.Y.Z --target main --title "ABS+ X.Y.Z" --note-file fastlane/metadata/android/en-US/changelogs/<versionCode>.txt
```

The Release workflow (`.forgejo/workflows/release.yml`, on Forgejo Actions) ships everything from that one release: the bundle to Google Play, the iPhone app to the App Store (build number = `versionCode`), the signed `absplus-X.Y.Z.apk` (and the same file as `absplus.apk`, which absplus.app links through `releases/latest`) to the release, both on git.borodutch.com and on the same release on the GitHub mirror (the workflow creates it there with the same title and notes, since releases don't mirror and the download links point at GitHub), and the new version to the F-Droid merge request while it's open. A previous version still waiting for review or in review is replaced on both stores. F-Droid builds the tag itself and publishes the APK only if its own build matches it. Run the workflow by hand (Actions → Release → Run workflow on git.borodutch.com) with mode `dry-run` to build everything and publish nothing, or `testflight-only` to upload the iPhone build without submitting it. The store texts and images in `fastlane/` link to `play/`.

## iOS

The SwiftUI app lives in `ios/` (iOS 26.1+, iPhone). Open `ios/ABSPlus.xcodeproj` in Xcode 27, or build from the command line:

```sh
xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination 'generic/platform=iOS Simulator' build
```

`ios/UITests/Tour.swift` walks through every screen against a real server and saves screenshots; see the comment at its top for the environment variables it needs.

## License

MIT
