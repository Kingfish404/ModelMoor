#!/usr/bin/env bash
set -euo pipefail

# TermKit's public wchar_t overload is not portable: on one Swift platform
# wchar_t is UInt32 (making the overload a redeclaration), while on another it
# is Int32 (making UnicodeScalar.value fail to type-check). Keep one public
# UInt32 entry point and hide the platform-native call behind a differently
# named helper.

patch_checkout() {
    local checkout="$1"
    local file="$checkout/Sources/TermKit/Core/WcWidth.swift"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    chmod u+w "$file"
    python3 - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
new = '''/// Platform-native wcwidth implementation.
private func termKitNativeWcWidth(_ char: wchar_t) -> Int32 {
    #if os(macOS)
    return wcwidth(char)
    #else
    return wcwidth_linux(char)
    #endif
}

/// Cross-platform wcwidth wrapper for a Unicode scalar value.
public func termKitWcWidth(_ char: UInt32) -> Int32 {
    termKitNativeWcWidth(wchar_t(Int(char)))
}
'''

if new in source:
    raise SystemExit(0)
start_marker = "/// Cross-platform wcwidth wrapper\n"
end_marker = "/// Extension for Character"
start = source.find(start_marker)
end = source.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit(f"unexpected TermKit WcWidth.swift contents: {path}")
path.write_text(source[:start] + new + "\n" + source[end:])
PY
}

patch_swiftterm_checkout() {
    local checkout="$1"
    local file="$checkout/Package.swift"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    chmod u+w "$file"
    python3 - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = '''        resources: [
            .process("Apple/Metal/Shaders.metal")
        ],
'''
new = '''        // ModelMoor's TUI does not use SwiftTerm's optional Metal backend.
        resources: [],
'''

if new in source:
    raise SystemExit(0)
if old not in source:
    raise SystemExit(f"unexpected SwiftTerm Package.swift contents: {path}")
path.write_text(source.replace(old, new, 1))
PY
}

checkout_roots=(.build/checkouts Apps/TUI/.build/checkouts)
if [[ -n "${SWIFTPM_PATCH_ROOTS:-}" ]]; then
    IFS=: read -r -a extra_roots <<< "$SWIFTPM_PATCH_ROOTS"
    checkout_roots+=("${extra_roots[@]}")
fi

found=0
for root in "${checkout_roots[@]}"; do
    checkout="$root/TermKit"
    if [[ -f "$checkout/Sources/TermKit/Core/WcWidth.swift" ]]; then
        if [[ ! -w "$checkout/Sources/TermKit/Core/WcWidth.swift" ]] && ! chmod u+w "$checkout/Sources/TermKit/Core/WcWidth.swift" 2>/dev/null; then
            continue
        fi
        patch_checkout "$checkout"
        found=$((found + 1))
    fi
done

for root in "${checkout_roots[@]}"; do
    checkout="$root/SwiftTerm"
    if [[ -f "$checkout/Package.swift" ]]; then
        if [[ ! -w "$checkout/Package.swift" ]] && ! chmod u+w "$checkout/Package.swift" 2>/dev/null; then
            continue
        fi
        patch_swiftterm_checkout "$checkout"
    fi
done

if [[ "$found" -eq 0 ]]; then
    echo "TermKit checkout not found; run SwiftPM resolve/test before applying this patch" >&2
    exit 1
fi

printf 'Patched %d TermKit checkout(s)\n' "$found"
