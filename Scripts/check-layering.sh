#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_imports() {
  local label="$1"
  local path="$2"
  local forbidden="$3"
  local matches
  if command -v rg >/dev/null 2>&1; then
    matches="$(rg -n "^[[:space:]]*import[[:space:]]+(${forbidden})([[:space:]]|$)" "$PROJECT_DIR/$path" -g '*.swift' || true)"
  else
    matches="$(grep -R -n -E --include='*.swift' "^[[:space:]]*import[[:space:]]+(${forbidden})([[:space:]]|$)" "$PROJECT_DIR/$path" || true)"
  fi
  if [[ -n "$matches" ]]; then
    echo "error: $label crossed its allowed dependency boundary:" >&2
    echo "$matches" >&2
    return 1
  fi
}

check_imports \
  "ModelMoorCore" \
  "Sources/ModelMoorCore" \
  "AppKit|SwiftUI|Security|Network|LocalAuthentication|Darwin|Glibc|TermKit|ModelMoorSystem|ModelMoorGateway|ModelMoorApplication"

check_imports \
  "ModelMoorApplication" \
  "Sources/ModelMoorApplication" \
  "AppKit|SwiftUI|Security|Network|LocalAuthentication|Darwin|Glibc|TermKit"

check_imports \
  "ModelMoorGateway" \
  "Sources/ModelMoorGateway" \
  "AppKit|SwiftUI|Security|Network|LocalAuthentication|Darwin|Glibc|TermKit|ModelMoorSystem|ModelMoorApplication"

check_imports \
  "modelmoor CLI" \
  "Sources/modelmoor" \
  "AppKit|SwiftUI|Security|Network|LocalAuthentication|Darwin|Glibc|TermKit"

check_imports \
  "TUIWidgets" \
  "Apps/TUI/Sources/TUIWidgets" \
  "AppKit|SwiftUI|Security|Network|LocalAuthentication|Darwin|Glibc|TermKit"

echo "Layering check passed: Core/Application/Gateway/CLI/TUIWidgets boundaries are clean"
