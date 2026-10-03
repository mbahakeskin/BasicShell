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
VERSION="0.4.0"
BUILD="$(date +%Y%m%d%H%M)"

swift build -c "$CONFIG"
BINARY=".build/$CONFIG/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
if [ "$CONFIG" = "release" ]; then
  strip -x "$APP/Contents/MacOS/$NAME"
fi

# Pages are told one language in Accept-Language: the first of the Mac's
# preferred languages that the app is localized in (measured: an app whose
# first language is Turkish sends "tr-TR,tr;q=0.9"). Declaring Turkish lets a
# Turkish-first Mac say so; everything else falls back to English.
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
  <key>NSLocationUsageDescription</key><string>A web page you allowed wants to know where you are.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>A web page you allowed wants to know where you are.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
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

# Signed with "BasicShell Local Signing" when that identity is in the
# keychain: a self-signed certificate that stays the same from build to build,
# so macOS keeps what it was told about the app (location, camera, microphone)
# instead of asking again after every build. Otherwise ad-hoc, which runs just
# as well but is a new app to macOS each time.
IDENTITY="$( (security find-certificate -c "BasicShell Local Signing" -Z 2>/dev/null || true) | awk '/SHA-1/ {print $3}')"
codesign --force --options runtime --entitlements "$NAME.entitlements" --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
