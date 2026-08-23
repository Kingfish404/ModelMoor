#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION="7.2.140"

case "$(uname -m)" in
  arm64)
    RELEASE_ARCH="aarch64"
    EXPECTED_SHA256="47aa529e29a75804283ad44206390e1c35b290e2c4e191739bd82759461ec7e7"
    ;;
  x86_64)
    RELEASE_ARCH="amd64"
    EXPECTED_SHA256="a4adccf70ce97ffbc10f0f38cf19be21e7d5d651bbf336719769af635a786820"
    ;;
  *)
    print -u2 "error: unsupported macOS architecture: $(uname -m)"
    exit 1
    ;;
esac

VENDOR_DIR="$PROJECT_DIR/.build/vendor/cliproxyapi/$VERSION/$RELEASE_ARCH"
BINARY="$VENDOR_DIR/cli-proxy-api"
LICENSE="$VENDOR_DIR/LICENSE"
ARCHIVE="$VENDOR_DIR/CLIProxyAPI_${VERSION}_darwin_${RELEASE_ARCH}.tar.gz"
RELEASE_URL="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${VERSION}/${ARCHIVE:t}"
LICENSE_URL="https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/v${VERSION}/LICENSE"

if [[ -x "$BINARY" && -s "$LICENSE" ]]; then
  print "$BINARY"
  exit 0
fi

mkdir -p "$VENDOR_DIR"
curl --fail --location --retry 3 --output "$ARCHIVE.tmp" "$RELEASE_URL"
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE.tmp" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  print -u2 "error: CLIProxyAPI archive checksum mismatch"
  rm -f "$ARCHIVE.tmp"
  exit 1
fi
mv "$ARCHIVE.tmp" "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$VENDOR_DIR"
if [[ ! -f "$BINARY" ]]; then
  print -u2 "error: CLIProxyAPI archive did not contain cli-proxy-api"
  exit 1
fi
chmod 755 "$BINARY"
curl --fail --location --retry 3 --output "$LICENSE.tmp" "$LICENSE_URL"
mv "$LICENSE.tmp" "$LICENSE"
print "$BINARY"
