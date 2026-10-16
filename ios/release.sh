#!/bin/bash
# Builds, signs and uploads the iPhone app to App Store Connect (CI: .github/workflows/release.yml).
#   ios/release.sh <version> <build number> [--no-upload]   (--no-upload stops after the export: build/export/ABSPlus.ipa)
# No signing identity needed: archive unsigned, sign ad hoc with the app's identity, and App Store Connect signs it for
# distribution during the export (cloud signing with the API key in ~/.appstoreconnect/private_keys).
set -eo pipefail
cd "$(dirname "$0")"
TEAM=ACWP4F58HZ
KEY=${ASC_KEY_ID:-3FT23S9NSM}
ISSUER=${ASC_ISSUER_ID:-a18f42ff-6c44-410c-badf-50b11de8dbb8}
P8=~/.appstoreconnect/private_keys/AuthKey_$KEY.p8
rm -rf build/ABSPlus.xcarchive build/export build/sign.entitlements
xcodebuild -project ABSPlus.xcodeproj -scheme ABSPlus -destination 'generic/platform=iOS' -archivePath build/ABSPlus.xcarchive \
  MARKETING_VERSION="$1" CURRENT_PROJECT_VERSION="$2" CODE_SIGNING_ALLOWED=NO archive | grep -E 'error:|ARCHIVE'
/usr/libexec/PlistBuddy -c "Add :application-identifier string $TEAM.com.borodutch.absplus" \
  -c "Add :com.apple.developer.team-identifier string $TEAM" build/sign.entitlements > /dev/null
codesign -f -s - --entitlements build/sign.entitlements build/ABSPlus.xcarchive/Products/Applications/ABSPlus.app
xcodebuild -exportArchive -archivePath build/ABSPlus.xcarchive -exportPath build/export -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates -authenticationKeyPath $P8 -authenticationKeyID $KEY -authenticationKeyIssuerID $ISSUER | grep -E 'error:|EXPORT'
[ "$3" = --no-upload ] && exit
xcrun altool --upload-app -f build/export/ABSPlus.ipa -t ios --apiKey $KEY --apiIssuer $ISSUER
