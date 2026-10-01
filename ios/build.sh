#!/bin/sh
# Sync ios/ to the Mac and build for the simulator: ./build.sh [extra xcodebuild args]
set -e
cd "$(dirname "$0")"
rsync -a --delete --exclude build ./ nikitas-macbook-pro:code/absplus-ios/
ssh nikitas-macbook-pro "cd ~/code/absplus-ios && xcodebuild -scheme ABSPlus -destination 'generic/platform=iOS Simulator' -derivedDataPath build $* build 2>&1" | grep -E 'error:|warning:|BUILD' | grep -v '^ld:' | sort -u | head -80
