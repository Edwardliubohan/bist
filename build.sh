#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
fail() { print -u2 -- "$*"; exit 1; }
[[ $(uname -s) == Darwin ]] || fail 'bist requires macOS 14 or later on an Apple Silicon Mac.'
macos_version=$(sw_vers -productVersion)
(( ${macos_version%%.*} >= 14 )) || fail 'bist requires macOS 14 Sonoma or later. Update macOS before building.'
[[ $(sysctl -in hw.optional.arm64 2>/dev/null) == 1 ]] || fail 'This build requires an Apple Silicon Mac (M1 or later).'
if ! xcrun --find swiftc >/dev/null 2>&1; then
    fail 'Apple build tools are missing. Run xcode-select --install, finish the installer, then retry.'
fi
command -v python3 >/dev/null 2>&1 || fail 'Python 3 is missing. Install the Xcode Command Line Tools with xcode-select --install.'
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
