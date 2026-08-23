#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_PROFILE="${MODELMOOR_BUILD_PROFILE:-${1:-production}}"

case "$BUILD_PROFILE" in
  production)
    APP_OUTPUT_DIR="$PROJECT_DIR/.build/app"
    APP_BUNDLE_NAME="ModelMoor.app"
    ;;
  development)
    APP_OUTPUT_DIR="$PROJECT_DIR/.build/app-dev"
    APP_BUNDLE_NAME="ModelMoor Dev.app"
    ;;
  *)
    print -u2 "error: build profile must be 'production' or 'development'"
    exit 1
    ;;
esac

APP_DIR="$APP_OUTPUT_DIR/$APP_BUNDLE_NAME"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
BUILD_OPTIONS=(--disable-sandbox --cache-path "$PROJECT_DIR/.build/cache")

cd "$PROJECT_DIR"
"$PROJECT_DIR/Scripts/generate-icons.sh"
CLIPROXY_BINARY="$("$PROJECT_DIR/Scripts/fetch-cliproxyapi.sh")"
# CLI ships from the root package; the macOS app lives in Apps/macOS so the
# root package stays buildable on Linux (docs/PLAN.md milestone B).
swift build $BUILD_OPTIONS -c release --product modelmoor
swift build $BUILD_OPTIONS -c release --package-path Apps/macOS
CLI_BINARY="$(swift build $BUILD_OPTIONS -c release --show-bin-path)/modelmoor"
APP_BINARY="$(swift build $BUILD_OPTIONS -c release --package-path Apps/macOS --show-bin-path)/ModelMoorApp"
APP_RESOURCE_BUNDLE="${APP_BINARY:h}/ModelMoorApp_ModelMoor.bundle"

if [[ "$APP_BINARY" -ef "$CLI_BINARY" ]]; then
  print -u2 "error: app and CLI products resolve to the same file"
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/Licenses"
cp "$APP_BINARY" "$APP_DIR/Contents/MacOS/ModelMoor"
cp "$CLIPROXY_BINARY" "$APP_DIR/Contents/MacOS/CLIProxyAPI"
cp "$PROJECT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
EN_LPROJ="$APP_RESOURCE_BUNDLE/en.lproj"
ZH_HANS_LPROJ="$APP_RESOURCE_BUNDLE/zh-hans.lproj"
for SOURCE_LPROJ in "$EN_LPROJ" "$ZH_HANS_LPROJ"; do
  if [[ ! -d "$SOURCE_LPROJ" ]]; then
    print -u2 "error: missing app localization resources: $SOURCE_LPROJ"
    exit 1
  fi
done
/usr/bin/ditto "$EN_LPROJ" "$APP_DIR/Contents/Resources/en.lproj"
/usr/bin/ditto "$ZH_HANS_LPROJ" "$APP_DIR/Contents/Resources/zh-Hans.lproj"
if [[ "$BUILD_PROFILE" == "development" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ModelMoor Dev" "$APP_DIR/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName ModelMoor Dev" "$APP_DIR/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.modelmoor.app.dev" "$APP_DIR/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :ModelMoorBuildProfile development" "$APP_DIR/Contents/Info.plist"
fi
APP_PACKAGE_CHECKOUTS="$PROJECT_DIR/Apps/macOS/.build/checkouts"
cp "$APP_PACKAGE_CHECKOUTS/swift-nio/Sources/NIOPosix/PrivacyInfo.xcprivacy" \
  "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$APP_PACKAGE_CHECKOUTS/swift-nio/LICENSE.txt" \
  "$APP_DIR/Contents/Resources/Licenses/SwiftNIO-LICENSE.txt"
cp "$APP_PACKAGE_CHECKOUTS/swift-nio/Sources/CNIOLLHTTP/LICENSE" \
  "$APP_DIR/Contents/Resources/Licenses/CNIOLLHTTP-LICENSE.txt"
cp "${CLIPROXY_BINARY:h}/LICENSE" \
  "$APP_DIR/Contents/Resources/Licenses/CLIProxyAPI-LICENSE.txt"
xcrun actool "$PROJECT_DIR/Resources/Assets.xcassets" \
  --compile "$APP_DIR/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$APP_OUTPUT_DIR/asset-info.plist"

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
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/CLIProxyAPI"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

print "Built $BUILD_PROFILE app: $APP_DIR"
print "CLI: $CLI_BINARY"
