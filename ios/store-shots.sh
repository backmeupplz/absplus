#!/bin/sh
# Takes the six store screenshots (UITests/StoreShots) in every app language on one simulator, each language from a
# fresh install, into $OUT/<language>/<n>.png. scripts/shots/compose.py then puts them under each locale's captions.
# Needs ABS_URL, ABS_USER, ABS_PASS: the public Audiobookshelf demo (https://audiobooks.dev, demo/demo) has the books
# the shots show. Optional:
#   DEVICE  simulator udid (default: the booted iPhone 18 Pro Max, for the 6.9" set); an iPhone Duo gives its cover display
#   UNFOLD  path to duo-hinge (github.com/tosbaha/duo-fold-control, tools/duo-hinge.m): takes the Duo's inner display
#           (landscape) instead. The test runner won't launch on an unfolded Duo, so each
#           language starts folded and the test asks for the unfold (StoreShots.unfold)
#   LANGS   languages to take, e.g. "de ar" (default: every language in Localizable.xcstrings)
#   OUT     output folder (default ./store-shots)
set -e
cd "$(dirname "$0")"
DEVICE="${DEVICE:-$(xcrun simctl list devices booted | sed -n 's/.*iPhone 18 Pro Max (\([0-9A-F-]*\)) (Booted).*/\1/p' | head -1)}"
[ -n "$DEVICE" ] || { echo "Boot an iPhone 18 Pro Max simulator or set DEVICE" >&2; exit 1; }
LANGS="${LANGS:-$(python3 -c 'import json; s = json.load(open("ABSPlus/Localizable.xcstrings"))["strings"]; print(" ".join(sorted({l for v in s.values() for l in v.get("localizations", {})} | {"en"})))')}"
OUT="$(mkdir -p "${OUT:-store-shots}" && cd "${OUT:-store-shots}" && pwd)"
DEST="platform=iOS Simulator,id=$DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl status_bar "$DEVICE" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active \
  --cellularBars 4 --batteryState charged --batteryLevel 100
xcodebuild -scheme ABSPlus -destination "$DEST" -derivedDataPath build build-for-testing > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
for lang in $LANGS; do
  xcrun simctl uninstall "$DEVICE" com.borodutch.absplus 2>/dev/null || true
  rm -rf "${OUT:?}/$lang"
  [ -z "$UNFOLD" ] || "$UNFOLD" -d "$DEVICE" closed > /dev/null
  TEST_RUNNER_ABS_URL="$ABS_URL" TEST_RUNNER_ABS_USER="$ABS_USER" TEST_RUNNER_ABS_PASS="$ABS_PASS" \
    TEST_RUNNER_SHOTS="$OUT/$lang" TEST_RUNNER_STORE_LANG="$lang" TEST_RUNNER_DUO_INNER="${UNFOLD:+1}" \
    xcodebuild -destination "$DEST" -derivedDataPath build -scheme ABSPlus -only-testing:UITests/StoreShots/testStoreShots \
    test-without-building > "$OUT/$lang.log" 2>&1 &
  # xcodebuild now and then hangs after the test is done, so six shots or ten minutes end it
  pid=$! waited=0
  while kill -0 $pid 2>/dev/null && [ $waited -lt 600 ]; do
    [ "$(ls "$OUT/$lang" 2>/dev/null | grep -c '^[1-6]-')" = 6 ] && { sleep 15; break; }
    [ -e "$OUT/$lang/unfold" ] && "$UNFOLD" -d "$DEVICE" flat > /dev/null && rm "$OUT/$lang/unfold"
    sleep 5; waited=$((waited + 5))
  done
  kill $pid 2>/dev/null || true
  grep -E 'StoreShots.swift:[0-9]+: error' "$OUT/$lang.log" | head -3
  echo "$lang: $(ls "$OUT/$lang" 2>/dev/null | tr '\n' ' ')"
done
