#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mode="${1:-device}"
if [[ "$mode" == test ]]; then
  device_id=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[v["udid"] for values in d["devices"].values() for v in values if v["name"].startswith("iPhone")]; print(ids[0] if ids else "")')
  [[ -n "$device_id" ]] || { printf '%s\n' 'No iPhone simulator runtime is installed.' >&2; exit 1; }
  # A local ad-hoc simulator signature is needed for the real Keychain tests.
  # The synthetic entitlement is never used by the device/IPA build below.
  xcodebuild -project Roadline.xcodeproj -scheme Roadline -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath build/test test CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS=Roadline/Simulator.entitlements ONLY_ACTIVE_ARCH=YES
elif [[ "$mode" == device ]]; then
  xcodebuild -project Roadline.xcodeproj -scheme Roadline -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/device build CODE_SIGNING_ALLOWED=NO
  mkdir -p build/package/Payload
  ditto build/device/Build/Products/Release-iphoneos/Roadline.app build/package/Payload/Roadline.app
  (cd build/package && /usr/bin/zip -qry ../Roadline-iOS-1.4.2-unsigned.ipa Payload)
  printf '%s\n' 'Created build/Roadline-iOS-1.4.2-unsigned.ipa. Sign before installing on an iPhone.'
else
  printf '%s\n' 'Usage: bash build-ios.sh [test|device]' >&2; exit 2
fi
