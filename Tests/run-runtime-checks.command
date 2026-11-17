#!/bin/bash
set -euo pipefail

case "${1:-}" in
    ""|--compile-only) ;;
    *) echo "Usage: $0 [--compile-only]"; exit 2 ;;
esac

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_file="$project_dir/Sources/M5GPUBoost.swift"
out_dir="$project_dir/build/runtime-checks"
combined="$out_dir/RuntimeChecks.swift"
binary_name="M5GPUBoostRuntimeChecks"
binary="$out_dir/$binary_name"

# The checks use private members, so they're compiled in the same file as the
# app source with the app's @main entry point removed.
if [[ "$(/usr/bin/grep -c '^@main$' "$source_file")" != 1 ]] \
    || ! /usr/bin/grep -A1 '^@main$' "$source_file" | /usr/bin/grep -q '^struct M5GPUBoostApp'; then
    echo "Expected exactly one @main, on struct M5GPUBoostApp, in $source_file"
    exit 1
fi

/bin/mkdir -p "$out_dir"
/usr/bin/awk '/^@main$/ { exit } { print }' "$source_file" > "$combined"
/bin/cat "$project_dir/Tests/RuntimeChecks.swift" >> "$combined"

/usr/bin/xcrun swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -module-cache-path "$project_dir/build/ModuleCache" \
    -target arm64-apple-macos26.0 \
    "$combined" \
    -o "$binary" \
    -framework AppKit \
    -framework CoreGraphics \
    -framework IOKit \
    -framework Metal \
    -framework SwiftUI

echo "Built: $binary"
if [[ "${1:-}" == "--compile-only" ]]; then
    exit 0
fi

# The checks save modes through UserDefaults. As a bare executable they use
# their own domain, never the app's; remove it afterwards.
trap '/usr/bin/defaults delete "$binary_name" >/dev/null 2>&1 || true' EXIT
"$binary"
