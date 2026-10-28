#!/bin/sh
# Runs the UI tour on a simulator and copies the screenshots to $OUT (default ./shots).
# Needs ABS_URL, ABS_USER, ABS_PASS. Optional:
#   SIM   simulator name (default "iPhone 18 Pro Max"), or DEST for a full xcodebuild destination
#         (e.g. DEST='platform=iOS Simulator,id=<udid>' for an iPhone Duo, cover or unfolded)
#   TEST  only this test (e.g. UITests/Tour/testTour, or UITests/FoldState for its cover/unfolded shots); default all
#   OUT   local folder for the screenshots
#   HOST  Mac to run on over ssh (default nikitas-macbook-pro); HOST=local runs on this Mac
#   RESET=1 to start logged out
set -e
cd "$(dirname "$0")"
SIM="${SIM:-iPhone 18 Pro Max}"
DEST="${DEST:-platform=iOS Simulator,name=$SIM}"
ONLY="${TEST:+-only-testing:$TEST}"
OUT="${OUT:-shots}"
HOST="${HOST:-nikitas-macbook-pro}"
run() {
  rm -rf /tmp/absplus-shots
  [ -z "$RESET" ] || xcrun simctl uninstall "$SIM" com.borodutch.absplus || true
  TEST_RUNNER_ABS_URL="$ABS_URL" TEST_RUNNER_ABS_USER="$ABS_USER" TEST_RUNNER_ABS_PASS="$ABS_PASS" TEST_RUNNER_SHOTS=/tmp/absplus-shots \
    xcodebuild -scheme ABSPlus -destination "$DEST" -derivedDataPath build $ONLY test 2>&1
}
if [ "$HOST" = local ]; then
  run | grep -E 'error|failed|passed|TEST SUCC|TEST FAIL' | head -20
  rm -rf "$OUT" && cp -R /tmp/absplus-shots "$OUT"
else
  rsync -a --delete --exclude build --exclude shots ./ "$HOST":code/absplus-ios/
  ssh "$HOST" "cd ~/code/absplus-ios && rm -rf /tmp/absplus-shots && \
    ([ -z '$RESET' ] || xcrun simctl uninstall '$SIM' com.borodutch.absplus || true) && \
    TEST_RUNNER_ABS_URL='$ABS_URL' TEST_RUNNER_ABS_USER='$ABS_USER' TEST_RUNNER_ABS_PASS='$ABS_PASS' TEST_RUNNER_SHOTS=/tmp/absplus-shots \
    xcodebuild -scheme ABSPlus -destination '$DEST' -derivedDataPath build $ONLY test 2>&1" \
    | grep -E 'error|failed|passed|TEST SUCC|TEST FAIL' | head -20
  rm -rf "$OUT" && scp -qr "$HOST":/tmp/absplus-shots "$OUT"
fi
ls "$OUT"
