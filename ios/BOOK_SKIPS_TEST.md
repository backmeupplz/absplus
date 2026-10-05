# Book-global skip regression (#28)

Run `sh ios/book-skips-test.sh` on a Mac with Xcode and the iOS 27.0 / iPhone 18 Pro simulator runtime. It creates and deletes its own disposable simulator and prints the preserved build/log/xcresult directory. No credentials, account, server, downloaded library, or shared simulator is used.

`BookSkipFixture` (Debug-only launch argument `--book-skip-test`) writes two synthetic PCM WAV files of 100 and 50 seconds and a local cover. Production `Player.start`, downloaded-file URL selection, AVQueuePlayer, and `FullPlayer` are used unchanged. No fake position calculator or mocked player stands in for AVFoundation. The fixture exposes the actual current item filename, `currentTime`, rate, default rate, readiness, and model position through an accessibility snapshot. XCTest waits for actual native positions (0.15-second tolerance), records them as xcresult attachments, and taps the real FullPlayer skip buttons.

Both FullPlayer and remote callback-body routes cover 110 back 30 = 80, 95 forward 30 = 125, within-file skips, repeated skips across files, exact end 150, overshoot end, back from end, beginning clamp, repeated clamping, preservation of paused state and 1.5x speed. A separate playing test checks both directions/routes retain an actual 1.5 AVQueuePlayer rate. Playing checks allow elapsed wall-clock time; exact arithmetic is asserted paused.

Remote limitation: public XCTest/MediaPlayer APIs do not synthesize OS/headset MPRemoteCommandEvents. Fixture buttons invoke `remoteSkipForward`/`remoteSkipBackward`, the shared callback bodies registered with MPRemoteCommandCenter. This proves the registered handler logic and native playback path, **not** OS delivery, Control Center, lock-screen rendering, Bluetooth, or headset dispatch. Those require physical-device/manual testing.

Only production semantic change: `Player.skip` clamps to the true book duration, not duration minus one. Loading/queue redesign belongs to #25 and is intentionally excluded.
