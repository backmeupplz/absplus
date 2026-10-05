# iOS session isolation (#33)

- Candidate login uses an explicit normalized base URL and does not change active host,
  tokens, offline state, or media selection until authentication validates and the live
  attempt/cancellation/generation guards pass. Latest main attempt wins. Linked login
  cannot replace the main account; dismissal, unlink, expiry and replacement invalidate it.
  Unlink invalidates all pending linked attempts because the server may canonicalize an
  entered alias (for example ALICE → alice) only after its response arrives.
- Every credential carries its host and account identity in the Keychain. Legacy tokens
  without provable origin require fresh login, rather than guessing their server.
- Every API/refresh request captures host, login generation (mediaEpoch), and account id
  before suspension. Both success and failure paths reject stale callbacks. Unlink
  captures its removed token's host; it never reads a later global host.
- Main login/logout clears account-specific JSON, progress, favorites/queues/shares,
  last-played state, cover caches, active playback and credential-bearing resume archives.
  Completed audio and allowlisted retained metadata are preserved in server-and-account
  scopes. Immutable server user IDs recover the same account; missing IDs use persisted
  per-login random ownership. Legacy server-only/unscoped media and JSON remain quarantined.
  Covers use the same server/account scope for disk, decoded memory, 404 negatives and
  in-flight deduplication; legacy `Caches/covers/<id>` is never read or migrated.
  Account cleanup is best-effort hygiene, not the ownership boundary. Epoch/cancellation
  checks still reject late cover responses before disk writes or decoded-image publication.
- No credential-bearing redirects are followed. Cover reads use the guarded API;
  foreground ephemeral downloads reject redirects (background URLSession cannot enforce
  this delegate). Legacy OS-owned downloads are cancelled, never adopted. No continued
  transfer while suspended/terminated is promised; queued missing files restart on launch.
  Downloads validate both archived resume request URLs before
  attaching a new token. Streaming uses AVAssetResourceLoader with explicit immutable
  URL/token, bounded byte-range requests and the no-redirect transport. Servers must
  support HTTP 206 byte ranges (the normal ABS file route).
- SwiftUI roots reset only on mediaEpoch change, not on routine list refresh/navigation.
  Login task handles cancel on dismissal; multi-request screen reloads stop at an epoch
  change. Existing #21 retained list context is preserved.

## Native regression fixtures

SessionIsolation runs actual URLSession requests between isolation-a.invalid and
isolation-b.invalid with synthetic credentials: same/different usernames, A refresh401
then B login/unlink, failure/cancellation, delayed main/linked login, refresh/read/error,
unlink during refresh and delayed canonicalized linked login, stale cover, persisted host
binding, and real AVFoundation range loading of generated silent WAV. The production
Downloader uses actual loopback TCP/HTTP fixtures: HTTP 200 commits valid WAV bytes;
HTTP 307 commits nothing and sends no request to the redirect sink. Same-server accounts
exercise a 403 metadata denial, production local-file resolution, preserved owner bytes,
same-account recovery, missing-ID restart and refresh isolation. Actual Covers.get checks
cache A, log in B, then inject surviving A scoped and unscoped cover files: B HTTP 403
reads and reconstructed/cold-cache reads return nil. Cases include distinct usernames,
the same username with different immutable IDs, missing IDs and different hosts. Memory
and 404 negatives are exercised across simultaneous reconstructed ownership contexts.
Sibling session JSON was inspected: `account-json/<mediaScope>` already uses the same
authenticated server/account ownership, with legacy `json/` quarantined. The fixture
injects A session JSON after cleanup and checks B/restart cannot read it; no analogous
unscoped production JSON namespace remains. Unsafe resume archives
are also asserted. No real server or credentials are used. RetainedDownloads and ListLifecycle
remain in the suite. Debug launch fixtures alone use a synthetic UserDefaults credential
store so unsigned simulator persistence does not depend on Keychain entitlements; release
continues using device-only Keychain. OfflineLibrary joins the same debug-only credential
store and authenticates via the synthetic OfflineHomeProtocol before writing scoped audio.

#34 integration: mediaEpoch is the persisted login/session generation. Its progress replay
must capture this generation plus recipient account identity, clear progress queues in
resetSession, and never substitute a later host/account after await. The separate active
#34 worktree was inspected read-only; no code was cherry-picked.

## Persistent cover ownership review fix (2026-10-04)

All six native suites passed on disposable ABS33-CoverScope: 9 tests, zero failures or
skips, finalized xcresult `Passed` at `/tmp/abs33-cover-full-suite.xcresult`; log
`/tmp/abs33-cover-full-suite.log`. Xcode exited 0 without diagnostic intervention on
this final run. Unsigned Release simulator build exited 0 (`/tmp/abs33-cover-release.log`).
The first focused attempt exposed a fixture filename assumption (hyphen percent-encoding),
corrected before the full run; its stalled post-test diagnostic child alone was stopped.
Existing AVAudioSession main-thread runtime warnings remain. Android was untouched and
was not rerun. No publication, signing or real account/server access.

## Local build evidence

Unsigned simulator Debug build-for-testing and Release build succeeded with Xcode 27.
Disposable device: ABS33-Isolation (D3CA39C0-35CE-43BF-AC27-01F873250333).
DerivedData: /tmp/abs33-ios-derived and /tmp/abs33-ios-release.
No signing, physical-device, TestFlight or App Store delivery claims.

Final native suite: 3 tests, 0 failures (ListLifecycle, RetainedDownloads, SessionIsolation).
Result bundle: /tmp/abs33-ios-final.xcresult; log: /tmp/abs33-ios-final.log.
Initial fixture failures were corrected by explicitly installing URLProtocol on the new
ephemeral transport and isolating the unsigned simulator synthetic credential store.
The final xcodebuild exited 0 and xcresulttool reports Passed, 3/3. Its post-test
simctl diagnose collector stalled; only that diagnostic child was terminated after all
tests finished, allowing normal result-bundle finalization. An existing AVAudioSession
main-thread activation warning remains; no test failures.
