# Retained downloads (#36)

**Retention applies only to new-format, server-scoped downloads.** All legacy unscoped bytes are preserved but quarantined for security; they are not automatically migrated.

Audio and an explicit item-metadata allowlist live under a SHA-256 server URL scope, separate from session caches/preferences. Logout removes credentials, user state and session JSON, not retained media. A successful online login selects the scope; failure does not select it. The existing signed-in offline flow uses retained item data immediately (books and podcast episodes), without refreshing each title. This is not offline authentication.

URL scope preserves scheme, host, port and base path, trimming surrounding whitespace and trailing slashes. Alias URLs intentionally do not share downloads. Unknown legacy unscoped files are left untouched but quarantined: old versions could mix multiple servers in the same directory, so matching an item ID or size is not evidence of ownership. They require downloading again; no unsafe automatic migration.

Only typed/allowlisted item title/author/description, type, episode identity and audio layout are retained, never arbitrary expanded-response fields, signed URLs, credentials, favorites, shares or progress. Android jobs capture scope/server/epoch. iOS background task descriptions carry a persisted login generation, unique transfer identity and scoped path; stale completion/restore callbacks are ignored/cancelled. Logout also removes iOS resume archives (which contain request authorization). A per-enqueue identity guards iOS authentication waits and scheduled retries, independently of terminal transfer cleanup. Explicit cancellation/session replacement resets retry budgets, while automatic retries remain bounded. Android session replacement clears both the in-memory and persisted queue.

## Integration with #33

The narrow candidate-login base URL and successful-login media selection here are necessary to avoid exposing a previous server's retained data after failed login. #33 owns transactional credential/account/server state and all non-download async operations. Integrate its committed session identity at selectMedia / mediaEpoch, preserving the generation guards around metadata writes and download callbacks. Do not restore global media paths or retain the general JSON cache on logout. Same-server retained files are intentionally server-owned, not account-owned; account permission enforcement is #33's boundary.

## Checks

- Android: ./gradlew testDebugUnitTest assembleDebug (includes RetainedTest and existing NavigationTest).
- iOS: xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:UITests/ListLifecycle -only-testing:UITests/RetainedDownloads test.
- Retained fixtures use synthetic HTTP/URLProtocol data, no personal library. iOS generates a valid PCM WAV and opens/plays it through AVAudioPlayer after re-login with all requests unavailable. The production AVQueuePlayer asset resolver is also checked, with an explicit zero additional item-metadata request assertion. Tests cover safe projection, same-ID alternate server, failed login, stale login/transfer completion, same-login cancellation/requeue (including suspended token refresh and scheduled retries), retry-budget reset versus automatic retry exhaustion, same-host relogin, Android queue reload after different-host login, cleanup after the title queue is pruned, and books/podcasts without per-item refresh.
