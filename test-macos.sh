#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != --fixtures-only ) ]]; then
    echo "Usage: $0 BUILD_OUTPUT_DIRECTORY [--fixtures-only]" >&2
    exit 2
fi
output="$(cd "$1" && pwd)"
shift
scratch="$(mktemp -d "${TMPDIR:-/tmp}/sue-paper-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$output/rust-target}"
cargo fmt --manifest-path "$root/Cargo.toml" -- --check
xcrun swift-format lint --strict "$root"/macos/*.swift
cargo test --locked --manifest-path "$root/Cargo.toml" --lib --bin export_textures
cargo clippy --locked --manifest-path "$root/Cargo.toml" --lib --bin export_textures -- -D warnings
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx12.0 \
    -module-cache-path "$output/module-cache" -framework AppKit \
    -parse-as-library "$root/macos/ForegroundFixture.swift" -o "$scratch/foreground-fixture"
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx12.0 \
    -module-cache-path "$output/module-cache" -framework AppKit \
    -import-objc-header "$root/macos/ScheduleBridge.h" "$CARGO_TARGET_DIR/release/libsue_paper.a" \
    "$root/macos/Schedule.swift" "$root/macos/ScheduleWindow.swift" \
    "$root/macos/Settings.swift" "$root/macos/Locale.swift" "$root/macos/Overlay.swift" \
    "$root/macos/IntensitySlider.swift" \
    "$root/macos/AppController.swift" "$root/macos/Tests.swift" \
    -o "$scratch/tests"
"$scratch/tests" "$output/Sue-Paper.app/Contents/Resources" "$scratch" "$output/test-results" \
    "$root/tests/schedule-zone.csv" "$@"
if [[ $# -eq 0 ]]; then
    "$output/Sue-Paper.app/Contents/MacOS/Sue-Paper" --smoke-test "$scratch/smoke"
fi
