# Transactional sessions (#33)

Candidate login requests use only the explicitly entered host and credentials. No global host, account, offline state or retained media selection changes on failure/cancellation. A successful main login starts a new generation and clears linked tokens, shares, progress, favorites and pending favorite changes, history, active download queue, current playback and session JSON, including same-name/same-host reauthentication. Retained audio and allowlisted metadata remain under SHA-256 server and authenticated-account scopes. The server-returned immutable user ID permits same-account recovery after re-login; a missing ID gets a fresh per-login identity, never a username-based guess. Legacy unscoped and server-only bytes remain quarantined, never deleted or guessed into an account. General JSON uses a persisted per-login cache directory on both platforms, so failed best-effort cleanup cannot expose another account’s cache or stale progress/bookmarks after same-account reauthentication. Android refresh preserves the login-established user ID when the refresh response omits it, but rejects an explicitly changed ID.

Account credentials persist their issuing host and login identity. Refresh/API/media requests capture that host and generation, not a later global host. Unlink revokes only at the stored issuing host. Session and account identity checks discard stale refresh/read/write callbacks and queued work. Login cancellation wins before commit; cancellation after an already completed commit does not undo a successful login. Legacy tokens without a provable host binding require signing in again; no token migration guesses. Main-login success deliberately resets account state rather than retaining stale linked authorization.

Authenticated transports reject HTTP redirects; configure the final server/base URL directly. Streaming transports also enforce the original session generation instead of attaching a new account token to an old player's URL. This changes redirect-dependent server configurations intentionally; no old-host credentials are forwarded to a redirect host. iOS authenticated downloads now use a foreground ephemeral URLSession because background URLSession always follows redirects without invoking the rejection delegate. Downloads therefore no longer promise continued transfer while suspended or terminated; persisted queued unfinished files restart when the app next launches; suspension alone does not guarantee continuation or automatic retry. Completed files remain available offline. Legacy background tasks are cancelled, not adopted into the new transport.

## Native regressions

- Android: ./gradlew testDebugUnitTest assembleDebug. SessionIsolationTest uses two disposable loopback HTTP servers and records actual request headers. Cases cover same/distinct usernames, refresh rejection then B login/unlink, failed/cancelled login, late linked login, late refresh/read/favorite callbacks, unlink during refresh, scheduled stale work, redirects and streaming request bytes. Same-server A/B account fixtures explicitly return 403 for restricted media and check metadata/local-file isolation, preserved A bytes and same-account recovery. A real Activity lifecycle and ExoPlayer service regression checks that login suppresses restoration and committed generation changes clear the actual queue, including local files. Existing navigation/retained/download tests remain enabled.
- iOS: xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:UITests/ListLifecycle -only-testing:UITests/RetainedDownloads -only-testing:UITests/SessionIsolation -only-testing:UITests/OfflineHome -only-testing:UITests/OfflineLibrary -only-testing:UITests/Accessibility test. Debug-only URLProtocol fixtures intercept disposable .invalid hosts for account isolation. Actual loopback HTTP downloads use the production Downloader session to check successful file receipt and rejected redirects with no sink request or committed redirected bytes. No real credentials or personal media.

## Integration

#36 commit 2e63698 was an essential dependency: without its media-path and metadata boundary a successful server switch could expose same-ID retained files from another server. It is included here as 9663822; do not duplicate it blindly. Its review fix ddd642da5b4b0dabfd59484d60a11909fef566b0 is included as 943bdad, retaining unique transfer ownership plus this branch’s session/reset/redirect guards. The transfer registry is cleared on session reset and legacy credential quarantine; callbacks remain identifiable even after the title queue is pruned. Preserve mediaEpoch/selectMedia guards and retained allowlist when merging later fixes.

Main 33d3058 (#35 exact offline episode filtering) is merged, preserving all four iOS suites in CI and all Android tests. Offline Home fixtures now authenticate only against synthetic local/URLProtocol hosts and seed the selected server scope; they do not bypass host binding or use legacy unscoped audio. The retained callback fixture supplies HTTP 200 responses so successful terminal callbacks actually exercise the production status gate.

#34 has not been cherry-picked. Its Abs login/token/api/logout hunks overlap: retain this transaction and immutable host/account generation checks; wire progressSync close/reset/wake at successful main commit/logout, not candidate login. Its allowed callback remains supported in Android api and must be checked again around refresh/retry. Re-run both suites after integration. #25 loading changes should retain Android sessionWork/bg ownership and iOS checkSession checks in addition to page loading ownership. #21 retained-navigation behavior is not intentionally changed.

Main 531eed6 (#11 offline Library native fixtures) is merged without dropping isolation, retained-download, accessibility, Home or navigation suites. Both Library fixtures authenticate against disposable synthetic transports and seed only the selected server/account scope. Empty books remain in Storage but are not playable Library titles. Android navigation seeds now use the correct scoped .mp3 paths.

Only the five-file delta 3066888..8843a91 from the stopped duplicate owner was inspected: the missing Android session JSON namespace, omitted-refresh-user-ID preservation, regressions and factual boundary documentation were incorporated. Existing cover account scopes and canonical linked-login guards remain intact. Historical artifact verification logs were not copied as evidence for this integration.

## Review-fix verification

- Android: 23 tests, zero failures; debug and release APK builds passed (`/tmp/abs33-account-player-verified.log`). The tool wrapper timed out during cleanup after Gradle reported success; process exit, test XML and APK artifacts were independently confirmed.
- iOS: isolation test passed in `/tmp/abs33-account-socket-ready.xcresult`; all three retained/offline/navigation regressions passed in `/tmp/abs33-account-recovered-regressions.xcresult`; release build passed (`/tmp/abs33-account-release-final.log`). A fixture listener-readiness race and simulator launch failure were recovered. A stalled post-test simulator diagnostic process was terminated after successful tests; final Xcode exit was zero.
- `git diff --check` passed.

## Integrated verification (2026-10-04)

- Android: testDebugUnitTest assembleDebug assembleRelease --offline --no-daemon --max-workers=2 exited 0; 33 tests, zero failures/skips; Debug and Release APKs built. Log: /tmp/abs33-integrated-android.log. The new restart fixture initially reused another Robolectric context; resetting it to this test's preferences/files corrected the harness, then the full suite passed.
- iOS: fresh unsigned Debug test build, all six selected suites passed (9 tests, zero failures/skips), finalized xcresult reports Passed: /tmp/abs33-integrated-tests.xcresult. Log: /tmp/abs33-integrated-tests.log. The post-test simctl diagnose child stalled; only that owned diagnostic child was terminated after all tests passed, allowing xcodebuild to finalize with exit 0. Existing AVAudioSession main-thread warnings remain.
- iOS unsigned Release simulator build also exited 0: /tmp/abs33-integrated-release.log. No production credentials or personal media were used; retained/legacy bytes remain preserved or quarantined.
- git diff --check passed. Independent integrated review and remote CI remain the parent's release gates.

Source/build fixture verification only; no production credentials, store rollout, signing or personal-device claims.

## Latest review corrections (#33)

Persistent Android artwork bindings include the login generation and item ID. The real Activity
regression keeps the same mini-player/download ImageViews across same-item account and host
switches and checks server-provided red/blue/green pixels through updatePlayer/updateDl.
The LibraryRecovery loopback fixture authenticates via production Abs.login; token validation
is unchanged. iOS general JSON now uses persisted Tok.id, with leftover-cache reauthentication,
refresh/restart and retained-media recovery assertions in SessionIsolation.

Android full suite: 44 tests, zero failures/errors/skips, including all nine LibraryRecovery tests;
debug/release APK builds exited 0 (/tmp/abs33-f169-android.log). The artwork fixture must attach
the Activity window with visible() for View.post delivery; it uses the existing graphics mode
(native-mode sandbox mixing was removed after a harness-only abort).

iOS: all eight existing suites passed together (13 tests, zero failures/skips), including
the new same-account JSON reauthentication regression inside SessionIsolation. Disposable
ABS33-f169-ReviewFix (9A662338-0141-4E3B-A181-94FCADEAC675), isolated DerivedData
/tmp/abs33-f169-derived; finalized Passed bundle /tmp/abs33-f169-tests.xcresult and log
/tmp/abs33-f169-tests.log. Only its stalled post-test simctl diagnose child was terminated
after all tests passed; Xcode finalized normally with exit 0. Unsigned Release simulator
build exited 0 (/tmp/abs33-f169-release.log). Existing AVAudioSession warnings remain.
No real credentials/library, physical devices, store publishing, or #34 scope changes.

## Retry recovery merge (#9 / 073a0df)

The retry policy is integrated with foreground redirect-rejecting transport, not background URLSession. The credential-neutral queue and per-file retry state are persisted atomically with the login identity; old unowned queue records are discarded, never assigned to the next account. Process-local transfers retain media-generation and unique-transfer guards; queue incarnation guards fence authentication waits. Successful login/logout cancels retries and removes the queue snapshot. Retry-After, budgets, terminal Retry/Cancel actions, completed siblings and interrupted-completion reconciliation remain intact. Fixed terminal messages avoid persisting request-bearing error descriptions. CI selects the union of all eight iOS suites plus the full Android suite.

Validation uses the isolated ABS33-RetryMerge simulator (15AF3FFE-0214-4830-AB2D-4D5B24F60756). Android testDebugUnitTest/assembleDebug/assembleRelease passed with 34 tests, zero failures (/tmp/abs33-retry-android.log). The unsigned iOS Release simulator build passed (/tmp/abs33-retry-release.log). The first focused four-test run passed (/tmp/abs33-retry-focused.xcresult). The union run passed 12/13 tests; the existing playback fixture raced AVQueuePlayer discarding its failed synthetic item. The fixture now holds that media response while inspecting the production player, preserving all isolation assertions; focused recovery results follow below.

Recovery passed all four retry/retained/isolation tests with zero failures/skips; xcodebuild exited 0 and the finalized bundle reports Passed (/tmp/abs33-retry-recovered.xcresult, /tmp/abs33-retry-recovered.log). The other nine tests passed in the union run (/tmp/abs33-retry-union.xcresult); no claim is made of a second full-union green run. Owned post-test simctl diagnostic children stalled and were terminated only after XCTest completed, allowing normal result finalization. Some read/staging command wrappers reported cleanup deadlines after printing complete output; actual staged state and native terminal results were checked. Existing AVAudioSession warnings remain. git diff --check passed. No publishing or board actions were performed.
