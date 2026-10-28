#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/bist.app/Contents/MacOS build/bist.app/Contents/Resources build/module-cache
xcrun swiftc -O -module-cache-path "$PWD/build/module-cache" -target arm64-apple-macosx14.0 Sources/*.swift -o build/bist.app/Contents/MacOS/bist
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
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleExecutable</key><string>bist</string>
<key>CFBundleIconFile</key><string>bist</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - build/bist.app
printf 'Built %s/build/bist.app\n' "$PWD"
