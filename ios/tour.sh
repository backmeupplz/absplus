#!/bin/sh
# Runs the UI tour on the Mac's simulator and copies the screenshots to ./shots.
# Needs ABS_URL, ABS_USER, ABS_PASS. Optional SIM (simulator name), RESET=1 to start logged out.
set -e
cd "$(dirname "$0")"
SIM="${SIM:-iPhone 18 Pro Max}"
rsync -a --delete --exclude build --exclude shots ./ nikitas-macbook-pro:code/absplus-ios/
ssh nikitas-macbook-pro "cd ~/code/absplus-ios && rm -rf /tmp/absplus-shots && \
  ([ -z '$RESET' ] || xcrun simctl uninstall '$SIM' com.borodutch.absplus || true) && \
  TEST_RUNNER_ABS_URL='$ABS_URL' TEST_RUNNER_ABS_USER='$ABS_USER' TEST_RUNNER_ABS_PASS='$ABS_PASS' TEST_RUNNER_SHOTS=/tmp/absplus-shots \
  xcodebuild -scheme ABSPlus -destination 'platform=iOS Simulator,name=$SIM' -derivedDataPath build test 2>&1" \
  | grep -E 'error|failed|passed|TEST SUCC|TEST FAIL' | head -20
rm -rf shots && scp -qr nikitas-macbook-pro:/tmp/absplus-shots shots
ls shots
