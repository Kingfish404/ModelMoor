#!/bin/sh

set -eu

if [ "$(uname -s)" != "Linux" ]; then
  echo "error: Linux is required to inspect ELF runtime dependencies" >&2
  exit 2
fi

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <executable> [executable ...]" >&2
  exit 2
fi

for binary in "$@"; do
  if [ ! -x "$binary" ]; then
    echo "error: not an executable file: $binary" >&2
    exit 2
  fi

  dependencies="$(ldd "$binary" 2>&1)" || {
    echo "error: unable to inspect runtime dependencies: $binary" >&2
    printf '%s\n' "$dependencies" >&2
    exit 1
  }

  printf '%s\n' "$binary"
  printf '%s\n' "$dependencies"

  if printf '%s\n' "$dependencies" | grep -Eq '(^|[[:space:]])(libswift[^[:space:]]*|libFoundation[^[:space:]]*|lib_Foundation[^[:space:]]*|libdispatch\.so[^[:space:]]*|libBlocksRuntime\.so[^[:space:]]*)'; then
    echo "error: release executable dynamically links a Swift runtime library: $binary" >&2
    echo "Build Linux release executables with --static-swift-stdlib." >&2
    exit 1
  fi

  if printf '%s\n' "$dependencies" | grep -q "not found"; then
    echo "error: release executable has an unresolved runtime dependency: $binary" >&2
    exit 1
  fi
done
