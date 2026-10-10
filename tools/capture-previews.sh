#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device_id=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for values in d["devices"].values() for v in values if v["name"].startswith("iPhone")))')
xcrun simctl boot "$device_id" 2>/dev/null || true
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" build/test/Build/Products/Debug-iphonesimulator/Roadline.app
xcrun simctl status_bar "$device_id" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
mkdir -p build/previews
for screen in home dashboard bmw; do
  SIMCTL_CHILD_ROADLINE_PREVIEW="$screen" xcrun simctl launch --terminate-running-process "$device_id" com.roadline.ios
  sleep 3
  xcrun simctl io "$device_id" screenshot "build/previews/$screen.png"
done
xcrun simctl terminate "$device_id" com.roadline.ios
