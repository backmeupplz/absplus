# iOS durable download retries (#32)

- Per-file attempt count, deadline, terminal message and authentication-refresh flag persist alongside the existing title queue. A transient failure never removes a title or its successful siblings.
- HTTP 408/429/5xx, transport interruption and rejected authentication get at most five automatic retries (2/4/8/16/32 seconds). Numeric and HTTP-date Retry-After are lower bounds, including across relaunch. Permanent/exhausted failures stay queued with visible Retry and Cancel actions; explicit Retry resets the budget.
- Deadlines are enforced by the foreground queue. While suspended iOS owns running background transfers; a timer is not a guarantee of execution while suspended. Pending delays resume on the next launch/foreground queue start.
- Persisted transfer identities fence stale callbacks after cancel/requeue/logout. Queue incarnation checks fence authentication waits. File save/size failures cannot silently look complete. Removing one episode no longer recursively removes siblings.
- Integrated with #36: retry keys use scoped rel/file paths and persisted mediaEpoch fences both token refresh and transfer callbacks. Successful main-login replacement cancels old authentication waits, retry deadlines and queue incarnations without removing retained audio. Retry fixtures select their synthetic scopes through successful production login, including across process relaunch. #33 remains separate; preserve these boundaries when integrating its session identity. #25 owns loading feedback; preserve both sets of UI/CI selectors.

## Native evidence

UITests/DownloadRetries exercises production delegate callbacks for 503 without resume data, 429 deadline persistence, partial siblings, permanent 404, exhausted persisted budgets, cancel/requeue stale callbacks and logout. A loopback HTTP endpoint additionally returns 503 once then 200 through the real background URLSession queue and checks no successful sibling is redownloaded. XCTest terminates/relaunches the app to verify a pending multi-file title and its Retry-After survive.

A separate native relaunch regression persists completed files with overdue retries and transfer identities, omits their completion callbacks, then verifies restore drains the queue with no surviving system tasks. It checks persisted retry/transfer cleanup, unchanged media bytes, stale resume-data removal, settled wakeups, and fetch-only reconciliation that preserves an unfinished sibling’s budget/deadline.

The loopback fixture also serves real `/auth/refresh` 429 and 503 with `Retry-After: 120`, verifies persisted deadlines and no 2-second retry/budget drain, holds a real refresh response across cancel/requeue and logout, and checks `Downloader.restore()` adopts two system-owned background transfers without duplicating them. HTTP errors retain Retry-After through token refresh and queue failure handling.

Android DownloadQueueTest covers existing behavior: controlled 503 then range-success, retained completed/partial siblings, durable queue reload and cancellation. No Android production semantics changed (bounded iOS retries are this ticket's scope); Android still uses its existing capped exponential waiting policy.

Local Android validation: 14 tests plus assembleDebug/assembleRelease passed (Gradle 9.8.0, JDK 21). iOS tests use an isolated ABS32-Retry simulator, not any sibling worker device. Commands: `./gradlew testDebugUnitTest assembleDebug assembleRelease`; `xcodebuild -project ios/ABSPlus.xcodeproj -scheme ABSPlus -destination <simulator> -only-testing:UITests/DownloadRetries -only-testing:UITests/ListLifecycle -only-testing:UITests/OfflineHome test`.

These are disposable native fixtures, not physical-device/store publication evidence. No personal credentials/library are used.
