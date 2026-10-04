# Android / iOS parity audit — 2026-10-04

Board: [#26](https://agentboard.icefish-betta.ts.net/#26). Audit-only: this report does not implement the follow-up fixes. Application snapshot: [`bf548dfd90c395efe33daceff944cf38dfad1fc0`](https://github.com/backmeupplz/absplus/commit/bf548dfd90c395efe33daceff944cf38dfad1fc0). Findings below refer to this immutable snapshot, not unmerged work on [loading #25](https://agentboard.icefish-betta.ts.net/#25).

## Source, build and release are different

| Evidence | Android | iOS |
|---|---|---|
| Audited source version | 1.1.2 / code 4 | 1.1.0 / build 2 |
| Latest public repository artifact | [v1.1.2 APK](https://github.com/backmeupplz/absplus/releases/tag/v1.1.2), published Oct 2; tag resolves `9d6f223b283818e82de8803f12bb4e9cb91edd2c` | No IPA attached to that release; no iOS publication workflow in this repository |
| Submission evidence | [Google Play run 37052983676](https://github.com/backmeupplz/absplus/actions/runs/37052983676) and upload step succeeded | App Store listing text and signing-team settings are not evidence of submission |
| Store approval / currently served version | Not verified: successful submission is not approval | Unknown; App Store Connect not accessed |
| Installed personal-device build | Not inspected | Not inspected |
| Scroll fix #21 | Merged Oct 4 in PR #1, after latest APK | Also merged in PR #1; not Android-only |

The source version labels did **not** change with #21, so “1.1.2” or “1.1.0” alone cannot identify whether a locally built app contains it. A fresh mobile release/build is separate from source merge and GitHub Pages delivery. The Android APK asset digest in release metadata is `sha256:d518621175e925a88928a50fd2a17cdfe42adfae90c55cc5b9e4d51d4cd5f134`; the asset was not installed on a personal device. No claim is made about the owner’s currently installed behavior.

## Recent changes traced

- [`2af2887`](https://github.com/backmeupplz/absplus/commit/2af288785c2f7dec0feeac9dabd46ecf81da5c6a): initial SwiftUI port, including playback/downloads/progress sharing.
- [`4979be1`](https://github.com/backmeupplz/absplus/commit/4979be1fe4797b2255c1ff6d05bbce7de21b235a): download progress, queue, cancel and restart recovery changed **both** platforms. Different queue APIs do not imply the iOS feature was omitted.
- [`d481b30`](https://github.com/backmeupplz/absplus/commit/d481b30e6438e314ef8f6a5f1c23333b4621e3f4): Android 13+ notification permission on first download. Intentionally Android-specific; iOS background URLSession does not require a foreground-service notification.
- Play upload/version commits `a4f8935`, `ab660cc`, `9d6f223` affect Android delivery, not missing iOS gameplay/features. iOS signing-team/screenshots commit `8cdf0b2` likewise does not prove a shipped feature difference.
- [PR #1](https://github.com/backmeupplz/absplus/pull/1), merged as audited snapshot: Android retained pages and stable identity/pixel anchors; iOS retained library data, native stable scroll targets and context reset. Android’s added offline-series regression has an iOS sibling gap described below.

## Evidence levels

“Source” means traced application control/data flow, not a device reproduction. “Fixture” means isolated synthetic data, never a personal library. Matching source behavior is not exhaustive runtime parity. Existing tests cover only a subset; green builds cannot certify the matrix. Physical hardware, real-server playback/background suspension and store installs remain unverified.

## Capability and behavior matrix

All file links below are pinned to the audited commit; line ranges in the matrix refer to those files.

| Area | Android | iOS | Verdict / source evidence |
|---|---|---|---|
| Library detail/back | Retained page/query, stable bound-card/pixel anchor | Retained data/query, native stable scroll target | Both fixed #21; Android Robolectric/JVM and iOS simulator fixtures passed. A-Main:189–225,319–385; I-Screens:62–120. Not proof for every shelf. |
| Search/filter/sort | Local case-insensitive title/author substring; library chips; offline filter | Local localized case-insensitive substring; title-menu picker; offline filter | Same basic scope; locale semantics differ. Both one title-sorted request, no selectable sort/pagination UI. A-Main:319–385; I-Screens:62–120. |
| Home | Server continue-listening limit20, local recent history; play tap/detail long-press | Same sources; play/context-menu details | Core match; both have episode-level offline filtering gap. A-Main:284–315; I-Screens:5–58. |
| Series | Book libraries, name-sorted series limit1000, shelf re-filters on return | Same query; shelf captures route cards | Core match; stale iOS shelf gap. A-Main:389–437; I-Screens:126–165; I-UI:240–267. |
| Favorites | Optimistic local change, server bookmark sync, pending mutations, metadata fill | Same bookmark convention and queue; observable cards | Core match. Android membership/viewport tests stronger. iOS offline empty-message gap linked #25. A-Main:441–467; A-Abs:285–340; I-Screens:170–184; I-Abs:458–503. |
| Detail/loading/error | Empty RecyclerView before uncached response; cached-first refresh, toast/auth errors | Empty List before item decoded; cached-first refresh, toast/auth errors | Shared gap, canonical #25. A-Main:666–671; I-Screens:372–390. |
| Podcasts | Audio-backed episodes newest first, episode playback/download, per-episode detail offline filter | Same | Source match; no real-server podcast test. A-Main:673–770; I-Screens:394–481. |
| Playback | Media3 multi-file timeline, seek, ±30 controls, 0.8–2×, last-title paused restore | AVQueuePlayer timeline, same controls/speeds, paused restore | Core match; Android ±30 is track-local, unlike iOS. A-Main:877–1003; I-Player:122–227. |
| Progress/shared resume | 20-second/pause/end sync, local/server positions, per-title linked-account choices | Same cadence, choices and sharing consent | Matching design, shared missing durable offline replay. A-Player:19–62; A-Abs:247–283; I-Player:66–117; I-Abs:418–455. |
| Downloads | Persisted serial queue, .part/Range, foreground notification, ring/bar/list, cancel one/all | Persisted queue, background URLSession/resume data, ring/bar/list, cancel one/all | Both received 1.1.0 changes. iOS sibling-removal and transient-retry gaps. A-Dl:25–181; I-Abs:310–408,534–642. |
| Offline/removal | Transport failure → downloaded-only views; local deletion; foreground connectivity retry | Same intended behavior | iOS incomplete-book/shelf gaps; both Home episode gap. No server deletion. A-Main:175–185; I-App:45–85. |
| Settings/auth | Server/account, link/unlink, storage, logout keeps media files | Same plus About links/version | Android About/accessibility omissions; shared unsafe server-switch scope and metadata-loss findings. A-Main:472–509; A-Abs:116–180; I-Screens:189–295; I-Abs:192–266. |
| Native integration | MediaSession/notification, audio focus/noisy handling, Material dynamic colors | Control Center/lock screen/interruption, AirPlay picker, SwiftUI | Appropriate OS conventions, not missing ports. A-Player:29–55; I-Player:23–65; I-UI:235–237. |

### Intentional differences and shared scope

Android system Back/chips/dialogs vs iOS edge-swipe/title menu/forms; Android explicit-tab reselect resets context, iOS per-tab NavigationStacks persist. iOS pull-to-refresh vs Android tab reselect refresh is a convention. Android serial foreground download and iOS background scheduling/force-quit restrictions cannot promise identical execution. AirPlay is native iOS UI, not an Android requirement.

Android app-private SharedPreferences (backup disabled) vs iOS device-only Keychain is a storage implementation difference, not proof other ordinary apps can read tokens. Both allow self-hosted HTTP, defaulting to HTTPS. Neither offers generic facets, user sort, chapters or sleep timer; shared absences are not new feature requests. Server-side truncation cannot be inferred merely from lack of a client pagination UI.

### Pinned source index

- [A-Main](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/app/src/main/java/com/borodutch/absplus/Main.kt) — `app/src/main/java/com/borodutch/absplus/Main.kt`
- [A-Abs](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/app/src/main/java/com/borodutch/absplus/Abs.kt) — `app/src/main/java/com/borodutch/absplus/Abs.kt`
- [A-Dl](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/app/src/main/java/com/borodutch/absplus/Dl.kt) — `app/src/main/java/com/borodutch/absplus/Dl.kt`
- [A-Player](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/app/src/main/java/com/borodutch/absplus/PlayerService.kt) — `app/src/main/java/com/borodutch/absplus/PlayerService.kt`
- [A-Ui](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/app/src/main/java/com/borodutch/absplus/Ui.kt) — `app/src/main/java/com/borodutch/absplus/Ui.kt`
- [I-Screens](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/ios/ABSPlus/Screens.swift) — `ios/ABSPlus/Screens.swift`
- [I-Abs](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/ios/ABSPlus/Abs.swift) — `ios/ABSPlus/Abs.swift`
- [I-Player](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/ios/ABSPlus/Player.swift) — `ios/ABSPlus/Player.swift`
- [I-UI](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/ios/ABSPlus/UI.swift) — `ios/ABSPlus/UI.swift`
- [I-App](https://github.com/backmeupplz/absplus/blob/bf548dfd90c395efe33daceff944cf38dfad1fc0/ios/ABSPlus/App.swift) — `ios/ABSPlus/App.swift`

## Confirmed findings and canonical work

Priorities: P1 = local data-loss/security boundary, P2 = functional reliability/parity, P3 = minor feature/accessibility omission. Every reproduction below is a deterministic proposed fixture procedure, not an assertion that a personal device ran it. All affect audited source; #27–36 underlying paths also exist in the v1.1.2 tag (iOS code there is version1.1.0/build2). Actual iOS distributed binary remains unknown. Follow-up tickets are tracked, **not fixed by this audit**.

### [#27 — Prevent ABS+ iOS episode removal from deleting sibling downloads](https://agentboard.icefish-betta.ts.net/#27)

P1 local offline data loss. I-Abs.swift:395-401 removes selected files then FileManager.removeItem(parent), which recursively deletes nonempty directory (Foundation primitive fixture confirmed). Android Abs.kt:228-232 File.delete(parent) preserves nonempty parents. Origin iOS 2af2887; queue cancellation also calls remove. Repro: save episodes A+B, remove A; B vanishes on iOS. Cancel partially downloading C also risks completed B. Acceptance: selected remove/cancel only affects selected episode tracks/partials; preserve all sibling completed/inflight files; remove-all still intentionally removes all; test both platforms including relaunch/offline and two saved episodes.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#28 — Make ABS+ Android 30-second skips cross audiobook file boundaries](https://agentboard.icefish-betta.ts.net/#28)

P2 parity gap. Main.kt:1000-1002 seekBack/seekForward uses current Media3 item; each file separate MediaItem (916-921), pinned Media3 1.11.1 BasePlayer.seekToOffset clamps to current item. iOS Player.swift:133-143 uses book-wide pos and Now.at. Repro 100s+50s files: at110s Back30 should80s but Android100s; at95s Forward30 should125s. Acceptance actual full-player and supported remote skip controls use whole-book timeline, clamp start/end correctly, preserve speed/pause; tests at file boundaries on both, not merely Now.at helper.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#29 — Refresh ABS+ iOS offline series shelves after download changes](https://agentboard.icefish-betta.ts.net/#29)

P2 missing sibling of #21 fix, not original scroll reset. Screens.swift:137-138 captures avail(cards) into Route.shelf; UI.swift:260 renders snapshot without availability refresh. Android Main.kt:420-436 recomputes avail on return/download change and anchors. Repro offline series A+B -> detail A -> remove -> back; iOS still shows A. Acceptance retain complete source roster, dynamically filter after remove/add/connectivity changes, preserve surviving title/pixel anchor across multiple callbacks; add iOS series/detail fixture parallel to Android NavigationTest cachedSeriesShelf, maintain both #21 suites.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#30 — Hide incomplete audiobooks from ABS+ iOS offline library](https://agentboard.icefish-betta.ts.net/#30)

P2 parity. Screens.swift:71 uses downloads().map directly; Abs.swift:372-378 enumerates any nonempty folder. Android Main.kt:337-350 avail requires complete book via Abs.kt:205-216. Repro two-file book first file complete second absent then offline: iOS lists unplayable full book, Android hides. Acceptance offline Library includes complete books and podcasts with at least one complete episode; partial files remain manageable in Storage Downloads; live mutation/scroll preserved; both-platform fixtures for partial/complete/zero completed.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#31 — Recover ABS+ Android selection when a library is removed or revoked](https://agentboard.icefish-betta.ts.net/#31)

P2 parity. Main.kt:358-379 only falls back when sel==null, not when stored ID absent from fresh list. iOS Screens.swift:95-99 validates membership. Repro selectA, remove accessA whileB exists, reopen: Android requestsA indefinitely until manual selection. Acceptance validate fresh library list, choose availableB/reset query+viewport for new context, empty list gives truthful empty state without stale requests, delayedA results cannot overwriteB. Retain #21 behavior, test both platforms.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#32 — Keep ABS+ iOS downloads queued across transient HTTP failures](https://agentboard.icefish-betta.ts.net/#32)

P2 reliability parity. Abs.swift:596-607 retries resume-data/401 only, otherwise removes entire matching title from dlq on503/429 with no resume data. Android Dl.kt:102-129 retains/retries408/429/5xx/IO. Repro controlled file endpoint503 once then200: iOS needs manual requeue and relaunch loses pending title. Acceptance durable bounded retry/backoff respecting Retry-After for transient failures, permanent error actionable, cancel/logout definitive, partial siblings retained; test multi-file title and relaunch both platforms.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#33 — Isolate ABS+ credentials and cached state when changing servers](https://agentboard.icefish-betta.ts.net/#33)

P1 security correctness, code-confirmed unsafe transition, no observed real credential leak. Both expired-session route opens login without logout; main login changes global server before success but preserves linked accounts keyed username. Android Abs.kt:126-139,143-148; iOS Abs.swift:201-222. Repro ONLY two disposable fixture hosts: loginA with linked account, reject A refresh (HTTP401), successfully log in to B, unlink old A linked account -> A refresh token can targetB/logout. Acceptance never send old-host credentials to new host; failed login cannot commit host change; transactional host/account scope clears or partitions tokens, shares, queues/cache/favorites/download metadata safely; tests both platforms incl same username, failure/cancel, expiry and unlink. No real secrets in fixtures/logs; do not broadly delete retained media.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#34 — Replay ABS+ offline listening progress after reconnect on both platforms](https://agentboard.icefish-betta.ts.net/#34)

P2 shared correctness, not one-sided parity. Android Abs.kt:275-283 and iOS Abs.swift:446-455 save local progress then swallow PATCH errors without durable dirty queue; reconnect only pings. Repro downloadedA offline play/pause or finish, quit, reconnect/reopen without replayA -> other device still stale. Acceptance durable per-title/episode pending own+authorized linked-account progress, replay reconnect/relaunch without playback, finished state retained, order/timestamps prevent stale overwrite, auth/retry/backoff handled, logout/share removal obey scope. Controlled-server tests both platforms.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#35 — Filter ABS+ offline Home by the actual downloaded podcast episode](https://agentboard.icefish-betta.ts.net/#35)

P2 shared correctness. Android Main.kt:299,600-601 and iOS Screens.swift:10-11/UI.swift:288-289 filter parent podcast downloaded(id), true when any sibling saved. Repro savedA + unsaved recentB same podcast -> offline Home offersB which cannot play. Detail filters already per episode. Acceptance Home continue/history only offers exact playable episode, complete books unchanged, live download/remove refresh retains navigation context; tests both platforms.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#36 — Keep retained ABS+ downloads usable after logout and same-server login](https://agentboard.icefish-betta.ts.net/#36)

P2 shared correctness. Logout says downloads kept, preserves audio but deletes expanded metadata needed by downloaded/cachedCard: Android Abs.kt:153-157,205-219; iOS Abs.swift:227-234,357-383. Repro download a non-favorite title, logout, relaunch, login same server online without opening that title, then go offline: Android excludes it/iOS Unknown item unrenderable. Acceptance preserve or rebuild safe server-scoped media metadata, retained downloads usable after valid same-server login without per-title online visit; no cross-server leakage, coordinate server-scope ticket, fixtures on both platforms; do not promise authenticated offline login.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### [#37 — Add ABS+ Android About information and accessible action names](https://agentboard.icefish-betta.ts.net/#37)

P3 small iOS parity omissions in Settings/details. Android Main.kt:472-509 lacks iOS Screens.swift:229-234 website/source/privacy/version; Android icon helper Ui.kt:95-99 and favorite/share/unlink controls lack contentDescription whereas iOS Screens.swift:211-212,443-448 labels. Acceptance equivalent About links/current build info using Android conventions and state-aware TalkBack labels for favorite/share/unlink/player actions, no debug copy; focused view/accessibility tests both platforms, manual TalkBack optional not gate.

Regression gap: existing CI does not assert this specific behavior; the ticket above owns implementation and its both-platform acceptance tests. Evidence is source-only except the isolated Foundation deletion primitive check for #27.

### Loading and empty/error feedback — existing #25

Both uncached detail screens are blank pending response. Also iOS offline Favorites filters grid through avail(app.fav) but tests raw app.fav.isEmpty for the overlay (I-Screens:172–175); favorite an undownloaded book then go offline → persistent blank result. Android checks filtered favorites (A-Main:445–455). These remain in [#25](https://agentboard.icefish-betta.ts.net/#25); no competing source edits/tickets. Android exhausted playback error visibility (A-Player:44–50 lacks onPlayerError, unlike I-Player:102–111) is a focused error-feedback validation target for #25, not proof all Media3 transient errors fail.

### Conditional targets, not promoted to confirmed gaps

Android cover requests lack bearer header unlike iOS; only a server/proxy requiring cover auth demonstrates impact. Android zero-size metadata treats missing files as complete (File.length==0) while iOS returns -1; ordinary known-positive files are unaffected. iOS successful HTTP transfer ignores move/storage failures; short-success/disk-full cases need a fixture. Both favorite uploaders classify all 4xx terminal, and revoked still-unexpired tokens lack explicit request-level refresh. Paused seeks, rapid same-title queue rebuilds and overlapping progress writes require timing fixtures before claiming observed data loss. These are test targets for the related download/auth/sync follow-ups, not independently verified device defects.


## Validation and limits

At the immutable application snapshot, in an isolated worktree:

- Android JDK21/SDK36: `./gradlew --offline --no-daemon testDebugUnitTest assembleDebug assembleRelease` **passed**, 11 Robolectric/JVM tests (7 NavigationTest, 3 DlTest, 1 NowTest), zero failures/errors. Debug/release APKs built; release uses debug signing absent release secrets, not a distributable store release.
- iOS Xcode27/iOS27 dedicated disposable simulator: `xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination "platform=iOS Simulator,id=<dedicated fixture simulator>" -derivedDataPath <isolated> -only-testing:UITests/ListLifecycle test` **passed**. One lifecycle test, including repeated toolbar/edge-swipe return, 500-title delayed fixture, query retention and new-library reset.
- iOS generic Simulator Release build **passed**. Simulator ad-hoc signing only; no distribution signing, upload or store operation.
- Existing exact-main [Checks run 37210231180](https://github.com/backmeupplz/absplus/actions/runs/37210231180) passed both platforms. This is baseline evidence, separate from this report PR’s checks.
- Isolated Foundation primitive fixture verified removing a nonempty directory removes its children. This supports #27, but is not app/UI playback/download verification. Android skip behavior traced to pinned [Media3 1.11.1 BasePlayer](https://github.com/androidx/media/blob/1.11.1/libraries/common/src/main/java/androidx/media3/common/BasePlayer.java), whose seekToOffset clamps the current MediaItem.

Coverage is asymmetric: Android NavigationTest covers offline Series removal and delayed Favorites membership; iOS ListLifecycle covers Library only. Android NowTest checks the mapping helper, not actual skip controls; DlTest checks Range behavior, not queue retry or cancellation. iOS Tour is a real-server screenshot/smoke test and is **not** run by current CI. Neither green build demonstrates background termination, hardware controls, full progress sync or actual store installs.

Local audit evidence: `/tmp/abs26-android.log`, `/tmp/abs26-ios.log`, `/tmp/abs26-ios-release.log`, `/tmp/abs26-ios-tests.xcresult`; Android XML results in the isolated worktree. No private server/library or personal device credentials used. Memory recall did not establish any additional iOS store release; no store status inferred from historical notes. GitHub job metadata verified the Play upload step; fetching its old raw log hit host CA validation, so no log-content claim is made and TLS verification was not disabled.

## Bottom line

The claim “Android fixes were not applied to iOS” is too broad: the two major recent changes (downloads and #21 navigation) touched both. The audit nevertheless found real mismatches in both directions and shared correctness defects; the follow-ups above are the canonical work. Android and iOS source/build labels differ, and latest public APK predates the navigation fix. Mobile release lag and implementation parity must be assessed separately.
