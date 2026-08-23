#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CATALOG="$PROJECT_DIR/Apps/macOS/Sources/ModelMoor/Resources/Localizable.xcstrings"
SOURCE_DIR="$PROJECT_DIR/Apps/macOS/Sources/ModelMoor"
EXTRACTION_DIR="$PROJECT_DIR/.build/localization-extraction"
CACHE_DIR="$PROJECT_DIR/.build/cache"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
SCRATCH_DIR="$PROJECT_DIR/.build/macos-localization-check"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -x "$XCODE_DEVELOPER_DIR/usr/bin/xcstringstool" ]]; then
  print -u2 "error: Xcode developer tools not found at $XCODE_DEVELOPER_DIR"
  exit 1
fi

mkdir -p "$EXTRACTION_DIR" "$CACHE_DIR" "$MODULE_CACHE" "$SCRATCH_DIR"

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
swift build \
  --package-path "$PROJECT_DIR/Apps/macOS" \
  --scratch-path "$SCRATCH_DIR" \
  --disable-sandbox \
  --disable-build-manifest-caching \
  --cache-path "$CACHE_DIR" \
  --jobs 1 \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path \
  -Xswiftc "$EXTRACTION_DIR"

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
xcrun swift \
  "$PROJECT_DIR/Scripts/check-localization-coverage.swift" \
  "$CATALOG" \
  "$EXTRACTION_DIR" \
  "$SOURCE_DIR"
