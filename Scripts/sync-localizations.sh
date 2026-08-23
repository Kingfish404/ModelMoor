#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CATALOG="$PROJECT_DIR/Apps/macOS/Sources/ModelMoor/Resources/Localizable.xcstrings"
EN_SIDECAR="$PROJECT_DIR/Apps/macOS/Sources/ModelMoor/Resources/en.lproj/Localizable.strings"
ZH_HANS_SIDECAR="$PROJECT_DIR/Apps/macOS/Sources/ModelMoor/Resources/zh-Hans.lproj/Localizable.strings"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CATALOG_TOOL="$XCODE_DEVELOPER_DIR/usr/bin/xcstringstool"
OUTPUT_DIR="$(mktemp -d /private/tmp/modelmoor-localizations.XXXXXX)"
trap 'rm -rf "$OUTPUT_DIR"' EXIT

if [[ ! -x "$CATALOG_TOOL" ]]; then
  print -u2 "error: xcstringstool not found at $CATALOG_TOOL"
  exit 1
fi

"$CATALOG_TOOL" compile "$CATALOG" \
  --output-directory "$OUTPUT_DIR" \
  --serialization-format text

COMPILED_EN="$OUTPUT_DIR/en.lproj/Localizable.strings"
COMPILED_ZH_HANS="$OUTPUT_DIR/zh-Hans.lproj/Localizable.strings"

if [[ $# -eq 1 && "$1" == "--check" ]]; then
  plutil -p "$COMPILED_EN" > "$OUTPUT_DIR/catalog-en.txt"
  plutil -p "$EN_SIDECAR" > "$OUTPUT_DIR/sidecar-en.txt"
  plutil -p "$COMPILED_ZH_HANS" > "$OUTPUT_DIR/catalog-zh-Hans.txt"
  plutil -p "$ZH_HANS_SIDECAR" > "$OUTPUT_DIR/sidecar-zh-Hans.txt"
  cmp "$OUTPUT_DIR/catalog-en.txt" "$OUTPUT_DIR/sidecar-en.txt"
  cmp "$OUTPUT_DIR/catalog-zh-Hans.txt" "$OUTPUT_DIR/sidecar-zh-Hans.txt"
  print "String Catalog and SwiftPM localization sidecars are in sync"
  exit 0
fi

if [[ $# -ne 0 ]]; then
  print -u2 "usage: $0 [--check]"
  exit 2
fi

/usr/bin/ditto "$COMPILED_EN" "$EN_SIDECAR"
/usr/bin/ditto "$COMPILED_ZH_HANS" "$ZH_HANS_SIDECAR"
print "Updated SwiftPM localization sidecars from Localizable.xcstrings"
