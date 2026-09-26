#!/bin/bash
# Wraps the SwiftPM binary in a double-clickable, ad-hoc signed BasicShell.app.
#
#   ./build.sh            release build into build/BasicShell.app
#   ./build.sh debug      same, from a debug build
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
NAME="BasicShell"
APP="build/$NAME.app"
ID="com.mbahakeskin.basicshell"
VERSION="0.1.0"
BUILD="$(date +%Y%m%d%H%M)"

swift build -c "$CONFIG"
BINARY=".build/$CONFIG/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
if [ "$CONFIG" = "release" ]; then
  strip -x "$APP/Contents/MacOS/$NAME"
fi

# The ad blocker's rules: EasyList and EasyPrivacy, turned into WebKit
# content rule lists (Tools/BlockLists.swift). Without Lists/ the app falls
# back to the short list built into Shield.swift.
[ -f Lists/easylist.txt ] || ./lists.sh || echo "no filter lists, using the built-in one" >&2
if [ -f Lists/easylist.txt ]; then
  mkdir -p .build/tools "$APP/Contents/Resources/Shield"
  if [ ! -x .build/tools/BlockLists ] || [ Tools/BlockLists.swift -nt .build/tools/BlockLists ]; then
    swiftc -O Tools/BlockLists.swift -o .build/tools/BlockLists
  fi
  .build/tools/BlockLists Lists/easylist.txt "$APP/Contents/Resources/Shield/ads.json"
  if [ -f Lists/easyprivacy.txt ]; then
    .build/tools/BlockLists Lists/easyprivacy.txt "$APP/Contents/Resources/Shield/privacy.json"
  fi
fi

# WebKit builds Accept-Language from the languages the app is localized in, so
# the bundle declares the ones the Mac is likely to prefer.
for lang in en tr; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSCameraUsageDescription</key><string>A web page you are visiting wants to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>A web page you are visiting wants to use the microphone.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.html</string><string>public.xhtml</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --options runtime --entitlements "$NAME.entitlements" --sign - "$APP"
echo "Built $APP"
