#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_SCRIPT="$SCRIPT_DIR/build-app.sh"

KEYCHAIN_SIGNING_COUNT="$(awk '
  /^[[:space:]]*codesign[[:space:]].*--sign[[:space:]]+"\$SIGN_IDENTITY"/ { count += 1 }
  END { print count + 0 }
' "$BUILD_SCRIPT")"

if [[ "$KEYCHAIN_SIGNING_COUNT" -ne 1 ]]; then
  print -u2 "error: build-app.sh must use the Keychain-backed identity exactly once; found $KEYCHAIN_SIGNING_COUNT"
  exit 1
fi

SIGNING_COMMANDS="$(awk '
  /^[[:space:]]*codesign[[:space:]]/ { collecting = 1 }
  collecting { printf "%s ", $0 }
  collecting && $0 !~ /\\[[:space:]]*$/ { collecting = 0 }
' "$BUILD_SCRIPT")"

if [[ "$SIGNING_COMMANDS" == *"--deep"* ]]; then
  print -u2 "error: signing must be explicitly ordered inside-out, not use deprecated --deep"
  exit 1
fi

case "$SIGNING_COMMANDS" in
  *'codesign --force --sign -'*'"$CLI_BINARY"'*'"$APP_DIR/Contents/MacOS/CLIProxyAPI"'*'codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"'*) ;;
  *)
    print -u2 "error: sign CLI/helper ad-hoc before signing the outer app once with its identity"
    exit 1
    ;;
esac
