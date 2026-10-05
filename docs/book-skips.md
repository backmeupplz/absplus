# Whole-book 30-second skips

Android's full-player buttons call MediaController.seekBack/seekForward. Media3 1.11.1 dispatches those commands via MediaSessionStub to the session Player. Its legacy platform rewind/fast-forward callback also delegates to Player.seekBack/seekForward. ExoPlayer's default implementation clamps inside the current media item, not the book.

PlayerService now installs a ForwardingPlayer that overrides only those two commands. It uses the existing Now track offsets/Abs.pos/Now.at conversion, clamps to the book's bounds, and seeks by playlist index plus file offset. It does not pause, play, rebuild the playlist, or change playback speed. A stale/mismatched Now cannot seek another title. The full-player UI and loading behavior are unchanged.

## Android regression

With JDK 21 and an Android SDK, run:

```sh
./gradlew testDebugUnitTest assembleDebug assembleRelease
```

BookSkipTest instantiates the real PlayerService/ExoPlayer, a real MediaSession and connected MediaController, and the real Main full-player dialog. Two locally generated WAV files last 100 and 50 seconds. Tests click the actual rewind/forward buttons and separately send Media3 controller commands; they inspect the service player's media index, file position, playWhenReady and speed (1.5x). Coverage includes 110−30=80, 95+30=125, within-file/repeated skips and both bounds, paused/playing intent, and stale/absent book/playlist safety. At the terminal bound only, the assertion permits ExoPlayer's duration-minus-one-millisecond resolution.

Regression sensitivity was verified by temporarily returning the session to the unwrapped ExoPlayer: both the full-player button and remote-controller tests failed at 110−30, reporting 100 instead of 80. Restoring BookPlayer makes both pass.

This is native Android/Robolectric integration coverage, not a physical Bluetooth or notification surface test. Android's platform MediaController transport in Robolectric did not dispatch to the service, so physical legacy transport remains a device smoke check; its Media3 delegation was traced, not claimed as end-to-end tested.

## iOS parity

See [iOS fixture instructions](../ios/BOOK_SKIPS_TEST.md). The fixtures use synthetic local audio, the real AVQueuePlayer, FullPlayer controls, and the same skip handlers registered with MPRemoteCommandCenter. OS Control Center/Bluetooth event delivery itself remains a device smoke check. No private library or credentials are needed.
