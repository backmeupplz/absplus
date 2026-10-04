# Transactional sessions (#33)

Candidate login requests use only the explicitly entered host and credentials. No global host, account, offline state or retained media selection changes on failure/cancellation. A successful main login starts a new generation and clears linked tokens, shares, progress, favorites and pending favorite changes, history, active download queue, current playback and session JSON, including same-name/same-host reauthentication. Retained audio and allowlisted metadata remain under #36's SHA-256 server scope; legacy unscoped bytes remain quarantined, never deleted or guessed into a new host.

Account credentials persist their issuing host and login identity. Refresh/API/media requests capture that host and generation, not a later global host. Unlink revokes only at the stored issuing host. Session and account identity checks discard stale refresh/read/write callbacks and queued work. Login cancellation wins before commit; cancellation after an already completed commit does not undo a successful login. Legacy tokens without a provable host binding require signing in again; no token migration guesses. Main-login success deliberately resets account state rather than retaining stale linked authorization.

Authenticated transports reject HTTP redirects; configure the final server/base URL directly. Streaming transports also enforce the original session generation instead of attaching a new account token to an old player's URL. This changes redirect-dependent server configurations intentionally; no old-host credentials are forwarded to a redirect host.

## Native regressions

- Android: ./gradlew testDebugUnitTest assembleDebug. SessionIsolationTest uses two disposable loopback HTTP servers and records actual request headers. Cases cover same/distinct usernames, refresh rejection then B login/unlink, failed/cancelled login, late linked login, late refresh/read/favorite callbacks, unlink during refresh, scheduled stale work, redirects and streaming request bytes. Existing navigation/retained/download tests remain enabled.
- iOS: xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:UITests/ListLifecycle -only-testing:UITests/RetainedDownloads -only-testing:UITests/SessionIsolation -only-testing:UITests/OfflineHome test. Debug-only URLProtocol fixtures intercept disposable .invalid hosts; no real credentials or personal media.

## Integration

#36 commit 2e63698 was an essential dependency: without its media-path and metadata boundary a successful server switch could expose same-ID retained files from another server. It is included here as 9663822; do not duplicate it blindly. Its review fix ddd642da5b4b0dabfd59484d60a11909fef566b0 is included as 943bdad, retaining unique transfer ownership plus this branch’s session/reset/redirect guards. The transfer registry is cleared on session reset and legacy credential quarantine; callbacks remain identifiable even after the title queue is pruned. Preserve mediaEpoch/selectMedia guards and retained allowlist when merging later fixes.

Main 33d3058 (#35 exact offline episode filtering) is merged, preserving all four iOS suites in CI and all Android tests. Offline Home fixtures now authenticate only against synthetic local/URLProtocol hosts and seed the selected server scope; they do not bypass host binding or use legacy unscoped audio. The retained callback fixture supplies HTTP 200 responses so successful terminal callbacks actually exercise the production status gate.

#34 has not been cherry-picked. Its Abs login/token/api/logout hunks overlap: retain this transaction and immutable host/account generation checks; wire progressSync close/reset/wake at successful main commit/logout, not candidate login. Its allowed callback remains supported in Android api and must be checked again around refresh/retry. Re-run both suites after integration. #25 loading changes should retain Android sessionWork/bg ownership and iOS checkSession checks in addition to page loading ownership. #21 retained-navigation behavior is not intentionally changed.

Source/build fixture verification only; no production credentials, store rollout, signing or personal-device claims.
