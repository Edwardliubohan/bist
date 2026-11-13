#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/bist.app/Contents/MacOS build/bist.app/Contents/Resources build/module-cache
xcrun swiftc -O -module-cache-path "$PWD/build/module-cache" -target arm64-apple-macosx14.0 -I Shared/Sources/CSQLite Shared/Sources/BistSync/*.swift Sources/*.swift -lsqlite3 -o build/bist.app/Contents/MacOS/bist
xcrun swift -module-cache-path "$PWD/build/module-cache" scripts/make-icon.swift build/BrandAssets
cp build/BrandAssets/bist.icns build/bist.app/Contents/Resources/bist.icns
cp scripts/bist-bobot.py docs/BOBOT.md build/bist.app/Contents/Resources/
cp Assets/bist-mark.svg Assets/bist-mark-animated.svg build/bist.app/Contents/Resources/
cat > build/bist.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>bist</string>
<key>CFBundleDisplayName</key><string>bist</string>
<key>CFBundleIdentifier</key><string>local.bist.panel</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleExecutable</key><string>bist</string>
<key>CFBundleIconFile</key><string>bist</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
python3 - <<'PYTHON'
import os
import plistlib
from pathlib import Path
p = Path('build/bist.app/Contents/Info.plist')
info = plistlib.loads(p.read_bytes())
# Only public connection values belong in a client app. The app validates them
# before use. Auth tokens stay in Keychain and setup credentials stay outside it.
info['BistSupabaseURL'] = os.environ.get('BIST_SUPABASE_URL', '')
info['BistSupabasePublishableKey'] = os.environ.get('BIST_SUPABASE_PUBLISHABLE_KEY', '')
p.write_bytes(plistlib.dumps(info, sort_keys=False))
PYTHON
codesign --force --sign - build/bist.app
printf 'Built %s/build/bist.app\n' "$PWD"
