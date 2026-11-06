# ABS+

ABS+ is a small, fast Audiobookshelf client for iPhone and Android that streams and downloads audiobooks and podcasts from your own [Audiobookshelf](https://www.audiobookshelf.org) server, so you can listen offline and pick up where you left off on any device. It's free and open source, with no ads and no analytics, and it's an independent app that isn't affiliated with or endorsed by the Audiobookshelf project.

- Website: https://absplus.app (source in `docs/`, served by GitHub Pages)
- Google Play: https://play.google.com/store/apps/details?id=com.borodutch.absplus
- App Store: https://apps.apple.com/app/id6818353284
- APK: [latest release](https://github.com/backmeupplz/absplus/releases/latest)

## How it compares

Checked on November 6, 2026, against the apps' own store listings and the Audiobookshelf docs' list of community apps.

- The **official Audiobookshelf app** comes from the Audiobookshelf project itself and runs on Android and iOS. ABS+ is a separate, smaller app that saves progress to the same server, so you can use both and each continues from the same spot.
- **ShelfPlayer** and **Plappa** are iPhone and iPad apps, and **Lissen** is an Android app. ABS+ is one app on both phones, built natively for each: about 4 MB on Android and 1 MB on iPhone.
- ABS+ is free in full, with no ads, no in-app purchases, no analytics and no account with us, and offline downloads are part of the free app. It talks only to the server you sign in to.
- ABS+ deliberately does less than the bigger apps: it plays, downloads and syncs audiobooks and podcasts, and it leaves managing your server to the Audiobookshelf web app.

## FAQ

**What are the best Audiobookshelf apps for iPhone and Android?** It depends on what you want. The official Audiobookshelf app covers both platforms, ShelfPlayer and Plappa are popular on iPhone, and Lissen is popular on Android. ABS+ is a good fit if you want the same small, ad-free app on both an iPhone and an Android phone.

**Is there a fast, ad-free Audiobookshelf client app?** ABS+ is one. It's a native app on each platform that opens straight to your library, and it has no ads, no tracking and nothing to buy.

**Can I listen offline?** Yes. Download a whole book or a single podcast episode, and when your server can't be reached, ABS+ switches to your downloads by itself and uploads your progress once you're back online.

**Do I need my own server?** Yes. ABS+ needs an Audiobookshelf server that you or someone you know runs, and you sign in with its address, your username and your password.

**Is ABS+ an official Audiobookshelf app?** No. It's an independent open-source app made by Nikita Kolmogorov, and it isn't affiliated with or endorsed by the Audiobookshelf project.

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
