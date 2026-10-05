# Loading suite tab-navigation diagnostics

The postmerge Checks run 37283513822 (job 111676870254) failed
LoadingLifecycle.testFailureRetryAndRepeatedNavigation at the last Retry
assertion, after the attempted Series → Favorites transition. The earlier
Home, Library, details and Series failures/retries all completed.

Artifact 11333674666 establishes a navigation failure, not a slow Favorites
request: the final AX hierarchy still has the Series navigation bar, two
Loaded series rows and the Series tab selected; Favorites is not selected.
The screen recording shows the Favorites selection animation springing back
to Series without displaying Favorites. The synthesized event is a single
50ms down/up at (329.5, 822), inside the Favorites button's AX frame
(282, 795, 95, 54). There is no fixture control over that tab (controls are
at y=111). Waiting longer for loading.retry on Series cannot establish
Favorites behavior.

LoadingLifecycle now sends one deliberate 100ms native press and asserts
that the requested tab becomes selected before examining its loading state.
This is not a repeated tap, a programmatic tab switch, or a loading timeout
increase. The existing initial/error/retry/content assertions and response
gates remain unchanged. The selection assertion makes an uncommitted gesture
fail at navigation rather than incorrectly blaming the destination request.
Production views, retained-error VStack, account scope and transport are
unchanged.

The hosted artifact proves the failed input/selection transition; it does not
prove why UIKit rejected that particular short gesture. Local Xcode 27 / iOS
27 does not reproduce the baseline failure (the original case passes). The
hosted runner used iOS 26.5. A fresh hosted run remains necessary to establish
that the deliberate gesture resolves that runner-specific failure. Local
native repeats, related suites and negative-control evidence are recorded in
the repair handoff; this is not physical-device evidence.
