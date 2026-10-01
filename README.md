# ABS+

A small, fast Android and iOS player for your own [Audiobookshelf](https://www.audiobookshelf.org) server. Free, no ads, no analytics.

- Website: https://absplus.app (source in `docs/`, served by GitHub Pages)
- Google Play: https://play.google.com/store/apps/details?id=com.borodutch.absplus
- APK: [latest release](https://github.com/backmeupplz/absplus/releases/latest)

## Build

JDK 21 and the Android SDK:

```sh
./gradlew assembleRelease
```

Without a `keystore.properties`, release builds are signed with the debug key.

## iOS

The SwiftUI app lives in `ios/` (iOS 26.1+, iPhone). Open `ios/ABSPlus.xcodeproj` in Xcode 27, or build from the command line:

```sh
xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination 'generic/platform=iOS Simulator' build
```

`ios/UITests/Tour.swift` walks through every screen against a real server and saves screenshots; see the comment at its top for the environment variables it needs.

## License

MIT
