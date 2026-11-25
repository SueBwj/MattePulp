#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$root/target/macos}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "Build on an Apple Silicon Mac with Xcode command line tools and Rust stable." >&2
    exit 1
fi
command -v cargo >/dev/null || { echo "Rust stable (cargo) is required." >&2; exit 1; }
mkdir -p "$output"
output="$(cd "$output" && pwd)"
if [[ -e "$output/Sue-Paper.app" || -e "$output/sue-paper-macos-arm64.zip" ]]; then
    echo "Output already contains an app or archive; choose a fresh output directory." >&2
    exit 1
fi
stage="$(mktemp -d "$output/.sue-paper-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Sue-Paper.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$output/rust-target}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$output/module-cache}"

cargo run --locked --release --manifest-path "$root/Cargo.toml" --bin export_textures -- \
    "$app/Contents/Resources/Textures"
cargo build --locked --release --manifest-path "$root/Cargo.toml" --lib
xcrun swiftc -swift-version 6 -warnings-as-errors -O -target arm64-apple-macosx12.0 \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" -framework AppKit \
    -import-objc-header "$root/macos/ScheduleBridge.h" "$CARGO_TARGET_DIR/release/libsue_paper.a" \
    "$root/macos/Schedule.swift" "$root/macos/ScheduleWindow.swift" \
    "$root/macos/Settings.swift" "$root/macos/Locale.swift" "$root/macos/Overlay.swift" \
    "$root/macos/IntensitySlider.swift" \
    "$root/macos/AppController.swift" "$root/macos/main.swift" \
    -o "$app/Contents/MacOS/Sue-Paper"
cp "$root/macos/Info.plist" "$app/Contents/Info.plist"
cp "$root/LICENSE" "$app/Contents/Resources/LICENSE"
iconset="$stage/SuePaper.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$root/assets/app-icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$root/assets/app-icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/SuePaper.icns"
plutil -lint "$app/Contents/Info.plist"
# Local ad-hoc integrity seal only. This is not Developer ID signing or notarization.
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto -c -k --keepParent "$app" "$stage/sue-paper-macos-arm64.zip"
mv "$app" "$output/Sue-Paper.app"
mv "$stage/sue-paper-macos-arm64.zip" "$output/sue-paper-macos-arm64.zip"
echo "Built: $output/Sue-Paper.app"
echo "Archive: $output/sue-paper-macos-arm64.zip"
