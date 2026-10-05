#!/bin/sh
# Local-only native regression: owns/deletes its simulator; never touches a shared device.
set -eu
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/absplus-book-skips-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUT"
SIM=$(xcrun simctl create "ABS28-Skips-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
cleanup() {
    xcrun simctl shutdown "$SIM" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIM"
    echo "Artifacts: $OUT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
set +e
xcodebuild -project ABSPlus.xcodeproj -scheme ABSPlus -configuration Debug \
    -destination "id=$SIM" -derivedDataPath "$OUT/build" \
    -resultBundlePath "$OUT/BookSkips.xcresult" -parallel-testing-enabled NO \
    -only-testing:UITests/BookSkips test CODE_SIGNING_ALLOWED=NO >"$OUT/test.log" 2>&1
STATUS=$?
set -e
cat "$OUT/test.log"
exit "$STATUS"
