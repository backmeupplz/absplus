# ABS+

A small, fast Android player for your own [Audiobookshelf](https://www.audiobookshelf.org) server. Free, no ads, no analytics.

- Website: https://absplus.app (source in `docs/`, served by GitHub Pages)
- Google Play: https://play.google.com/store/apps/details?id=com.borodutch.absplus
- APK: [latest release](https://github.com/backmeupplz/absplus/releases/latest)

## Build

JDK 21 and the Android SDK:

```sh
./gradlew assembleRelease
```

Without a `keystore.properties`, release builds are signed with the debug key.

## License

MIT
