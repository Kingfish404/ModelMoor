#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE_SVG="$PROJECT_DIR/Resources/Brand/ModelMoor-AppIcon-Master.svg"
MASTER_PNG="$PROJECT_DIR/Resources/Brand/ModelMoor-AppIcon-Master.png"
PREVIEW_PNG="$PROJECT_DIR/Resources/Brand/ModelMoor-AppIcon-1024.png"
ICON_DIR="$PROJECT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"

ICON_FILES=(
  icon_16x16.png
  icon_16x16@2x.png
  icon_32x32.png
  icon_32x32@2x.png
  icon_128x128.png
  icon_128x128@2x.png
  icon_256x256.png
  icon_256x256@2x.png
  icon_512x512.png
  icon_512x512@2x.png
)
ICON_PIXELS=(16 32 32 64 128 256 256 512 512 1024)

if [[ ! -f "$SOURCE_SVG" ]]; then
  print -u2 "error: missing app icon source: $SOURCE_SVG"
  exit 1
fi

GENERATED_FILES=("$MASTER_PNG" "$PREVIEW_PNG")
for filename in $ICON_FILES; do
  GENERATED_FILES+=("$ICON_DIR/$filename")
done

needs_generation=false
for output in $GENERATED_FILES; do
  if [[ ! -f "$output" || "$SOURCE_SVG" -nt "$output" ]]; then
    needs_generation=true
    break
  fi
done

if [[ "$needs_generation" == false ]]; then
  print "App icon rasters are up to date"
  exit 0
fi

mkdir -p "$ICON_DIR"

if (( $+commands[rsvg-convert] )); then
  rsvg-convert -w 1024 -h 1024 -o "$MASTER_PNG" "$SOURCE_SVG"
elif (( $+commands[inkscape] )); then
  inkscape "$SOURCE_SVG" \
    --export-area-page \
    --export-background-opacity=0 \
    --export-width=1024 \
    --export-height=1024 \
    --export-filename="$MASTER_PNG" >/dev/null
else
  print -u2 "error: generating AppIcon PNGs requires rsvg-convert or Inkscape"
  print -u2 "Install one with: brew install librsvg"
  exit 1
fi

cp "$MASTER_PNG" "$PREVIEW_PNG"

for index in {1..${#ICON_FILES}}; do
  filename="${ICON_FILES[$index]}"
  pixels="${ICON_PIXELS[$index]}"
  sips -z "$pixels" "$pixels" "$MASTER_PNG" \
    --out "$ICON_DIR/$filename" >/dev/null
done

print "Generated AppIcon rasters from $SOURCE_SVG"
