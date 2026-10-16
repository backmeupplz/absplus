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

Bump `versionCode` and `versionName` in `app/build.gradle.kts`, add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` (one or two plain sentences, F-Droid and Google Play both show them), merge, then publish the release:

```sh
gh release create vX.Y.Z --target main --title "ABS+ X.Y.Z" --notes-file fastlane/metadata/android/en-US/changelogs/<versionCode>.txt
```

The Google Play workflow sends the bundle to Play and attaches the signed `absplus-X.Y.Z.apk`. F-Droid builds the tag itself and publishes that APK only if its own build matches it. The store texts and images in `fastlane/` link to `play/`.

## iOS

The SwiftUI app lives in `ios/` (iOS 26.1+, iPhone). Open `ios/ABSPlus.xcodeproj` in Xcode 27, or build from the command line:

```sh
xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination 'generic/platform=iOS Simulator' build
```

`ios/UITests/Tour.swift` walks through every screen against a real server and saves screenshots; see the comment at its top for the environment variables it needs.

## License

MIT
