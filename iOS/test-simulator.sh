#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --find xcodebuild >/dev/null
mkdir -p build
BIST_UI_RUN_DIR=$(mktemp -d "$PWD/build/iphone-ui.XXXXXX")
xcrun simctl list devices available -j > build/simulators.json
BIST_SIMULATOR_ID=$(python3 - <<'PYTHON'
import json
from pathlib import Path

devices = json.loads(Path('build/simulators.json').read_text())['devices']
candidates = [device for runtime, group in devices.items() if 'iOS' in runtime
              for device in group if device.get('isAvailable') and device['name'].startswith('iPhone')]
if not candidates:
    raise SystemExit('No available iPhone simulator runtime')
print(candidates[0]['udid'])
PYTHON
)
xcodebuild -project iOS/Bist.xcodeproj -scheme 'Bist iPhone' \
  -destination "platform=iOS Simulator,id=$BIST_SIMULATOR_ID" \
  -derivedDataPath build/xcode-ui -resultBundlePath "$BIST_UI_RUN_DIR/BistPhoneUITests.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
