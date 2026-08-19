#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/.build/app/ModelMoor.app"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
BUILD_OPTIONS=(--disable-sandbox --cache-path "$PROJECT_DIR/.build/cache")

cd "$PROJECT_DIR"
"$PROJECT_DIR/Scripts/generate-icons.sh"
swift build $BUILD_OPTIONS -c release
BIN_DIR="$(swift build $BUILD_OPTIONS -c release --show-bin-path)"
APP_BINARY="$BIN_DIR/ModelMoorApp"
CLI_BINARY="$BIN_DIR/modelmoor"

if [[ "$APP_BINARY" -ef "$CLI_BINARY" ]]; then
  print -u2 "error: app and CLI products resolve to the same file"
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/Licenses"
cp "$APP_BINARY" "$APP_DIR/Contents/MacOS/ModelMoor"
cp "$PROJECT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/.build/checkouts/swift-nio/Sources/NIOPosix/PrivacyInfo.xcprivacy" \
  "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$PROJECT_DIR/.build/checkouts/swift-nio/LICENSE.txt" \
  "$APP_DIR/Contents/Resources/Licenses/SwiftNIO-LICENSE.txt"
cp "$PROJECT_DIR/.build/checkouts/swift-nio/Sources/CNIOLLHTTP/LICENSE" \
  "$APP_DIR/Contents/Resources/Licenses/CNIOLLHTTP-LICENSE.txt"
xcrun actool "$PROJECT_DIR/Resources/Assets.xcassets" \
  --compile "$APP_DIR/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$PROJECT_DIR/.build/app/asset-info.plist"

SIGN_IDENTITY="${MODELMOOR_CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/^[[:space:]]*[0-9]+\)/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  print -u2 "warning: no stable code-signing identity found; using ad-hoc signing"
  print -u2 "warning: set MODELMOOR_CODE_SIGN_IDENTITY to keep Keychain access stable across builds"
else
  print "Signing with $SIGN_IDENTITY"
fi

codesign --force --sign "$SIGN_IDENTITY" "$CLI_BINARY"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

print "Built $APP_DIR"
print "CLI: $CLI_BINARY"
