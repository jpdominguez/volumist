#!/bin/zsh
# Builds build/Volumist.app and build/Volumist-<version>.zip. Needs only the Command Line Tools.
# The app is ad hoc signed. Set SIGN_IDENTITY to sign with a Developer ID certificate instead.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Volumist"

APP=build/Volumist.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns CHANGELOG.md "$APP/Contents/Resources/"
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier io.github.jpdominguez.volumist "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ditto -c -k --keepParent "$APP" "build/Volumist-$VERSION.zip"
echo "Done: $APP and build/Volumist-$VERSION.zip"
