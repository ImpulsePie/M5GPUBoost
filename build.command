#!/bin/bash
set -euo pipefail

case "${1:-}" in
    ""|--no-open) ;;
    *) echo "Usage: $0 [--no-open]"; exit 2 ;;
esac

app_name="M5GPUBoost"
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$project_dir/build"
app_dir="$build_dir/$app_name.app"
previous_dir="$build_dir/previous"

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple's Swift toolchain is unavailable."
    /usr/bin/xcrun --find swiftc >&2 || true
    echo "Run: xcode-select --install"
    exit 1
fi

# Build into a fresh staging folder so a failed build never touches the
# existing app. Only the staging folder this script created is removed.
/bin/mkdir -p "$build_dir"
staging_dir="$(/usr/bin/mktemp -d "$build_dir/.staging.XXXXXX")"
trap '/bin/rm -rf "${staging_dir:?}"' EXIT

staged_app="$staging_dir/$app_name.app"
contents_dir="$staged_app/Contents"
/bin/mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
/bin/cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
/bin/cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"

/usr/bin/xcrun swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -module-cache-path "$build_dir/ModuleCache" \
    -target arm64-apple-macos26.0 \
    "$project_dir/Sources/$app_name.swift" \
    -o "$contents_dir/MacOS/$app_name" \
    -framework AppKit \
    -framework CoreGraphics \
    -framework IOKit \
    -framework Metal \
    -framework SwiftUI

/usr/bin/codesign --force --sign - "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"

# Keep the previous build instead of deleting it.
if [[ -e "$app_dir" ]]; then
    /bin/mkdir -p "$previous_dir"
    kept="$previous_dir/$app_name-$(/bin/date +%Y%m%d-%H%M%S).app"
    /bin/mv "$app_dir" "$kept"
    echo "Previous build moved to: $kept"
fi
/bin/mv "$staged_app" "$app_dir"

echo
echo "Built: $app_dir"
if [[ "${1:-}" == "--no-open" ]]; then
    exit 0
fi
if /usr/bin/pgrep -x "$app_name" >/dev/null; then
    echo "$app_name is already running. Quit it first so two copies don't both submit GPU work."
    exit 0
fi
echo "Opening $app_name…"
/usr/bin/open "$app_dir"
