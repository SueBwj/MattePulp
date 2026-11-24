# MattePulp

[中文](README.md) | **English**

<p align="center">
  <img src="assets/app-icon.png" width="128" alt="MattePulp icon: two overlapping translucent sheets on a dark blue field">
</p>

**MattePulp covers the screen with a generated paper texture so a bright display reads like matte paper.**

<p align="center">
  <img src="assets/showcase1.png" width="32%" alt="Paper grain over a reading page">
  <img src="assets/showcase2.png" width="32%" alt="The same reading page with a highlighted passage under the grain">
  <img src="assets/showcase3.png" width="32%" alt="A later page in the same reading view, still under the grain">
</p>

## Download

Download a published package first. The bilingual menus in this source tree are not in those packages yet.

| System | Release | File |
|---|---|---|
| Windows x64 | [v0.1.0](https://github.com/SueBwj/MattePulp/releases/tag/v0.1.0) stable | [sue-paper-v0.1.0-windows-x64.zip](https://github.com/SueBwj/MattePulp/releases/download/v0.1.0/sue-paper-v0.1.0-windows-x64.zip) |
| Mac Apple Silicon | [v0.1.1-macos.1](https://github.com/SueBwj/MattePulp/releases/tag/v0.1.1-macos.1) prerelease | [Sue-Paper-macOS-arm64-local-d9fb2c7.dmg](https://github.com/SueBwj/MattePulp/releases/download/v0.1.1-macos.1/Sue-Paper-macOS-arm64-local-d9fb2c7.dmg) |

Windows v0.1.0 (`53b266a`) still has the older tray art and a single-language UI with no language menu. The Mac prerelease (`d9fb2c7`, Apple Silicon only) already uses the current translucent paper icon, but menus stay mixed Chinese/English with no separate language item. The disk image is ad-hoc signed and not notarized; Gatekeeper may block a network download. Older `settings.json` files without a `language` field still load.

## Usage

The texture covers every screen. The pointer and keyboard pass through it; it does not take focus or appear in window switching. Mac display limits are in the [Mac notes](macos/README.md#display-behavior).

Four textures come from fractal noise and tile without a seam. Texture ids match the published packages (table below); intensity uses a 15%-30% slider in 1% steps on macOS and 4 levels (15% / 20% / 25% / 30%) on Windows.

| Settings id | English menu | Chinese menu | Character |
|---|---|---|---|
| ClassicMatte | Classic Matte | 经典哑光 | Clean, soft grain for reading |
| WhisperWeave | Whisper Weave | 织物纹理 | A fine weave that softens bright windows |
| Parchment | Sunbaked Parchment | 羊皮纸 | Warm, heavier grain |
| VellumMist | Vellum Mist | 薄纱雾面 | A light haze |

In a Windows build from this source, the Snooze menu adds "Resume now" while snoozing, which ends that snooze immediately. Snooze is not written to settings. When the foreground app is already excluded, the menu offers to include it, and the change takes effect immediately. The v0.1.0 package does not include these two actions.

![Four textures over the same horizontal lines](showcase/textures.png)

**Windows.** Unzip the stable package and run `sue-paper.exe`. When you build this source tree, right-click the tray icon: enable texture, texture/intensity/snooze, exclude the current app, language (中文 or English), and quit. The tray tip is 柔纸 in Chinese and MattePulp in English. Settings live in `%APPDATA%\Sue-Paper\settings.json`.

**Mac.** The published image still has the mixed menu and four fixed intensity items. Build `Sue-Paper.app` from this source and click **S** in the menu bar for a one-language menu with a separate language item and a focusable intensity slider panel (15%-30%, 1% steps: drag previews live and saves on release; arrow keys and accessibility adjustments save on every step). Finder shows MattePulp; the executable remains `Sue-Paper`. Settings live in `~/Library/Application Support/Sue-Paper/settings.json`. The app asks for neither Accessibility nor Screen Recording permission.

With no saved language, the menu follows the system UI language. A choice is stored as `language` (`zh-Hans` or `en`); Windows and Mac use the same rules.

## Build and test

### Windows

Requires Rust stable (`stable-x86_64-pc-windows-gnu` or MSVC):

```sh
./build-release.ps1
```

The script writes `target/release/sue-paper.exe`, embeds `assets/sue-paper.ico`, and copies the repository `LICENSE` beside the executable. Ship only `sue-paper.exe` and that `LICENSE`, not the whole `target\release` tree.

```sh
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
```

### macOS (Apple Silicon)

Requires macOS 12+, Rust stable, and Xcode 16+ (`xcrun` must find Swift 6 and `swift-format`):

```sh
./build-macos.sh /tmp/mattepulp-build
./test-macos.sh /tmp/mattepulp-build
open /tmp/mattepulp-build/Sue-Paper.app
```

Use a fresh output directory each time. Outputs are `Sue-Paper.app` and `sue-paper-macos-arm64.zip`; `LICENSE` is in `Contents/Resources`, with an ad-hoc signature. Tests use temporary settings and synthetic windows and do not capture the desktop. See the [Mac build and validation notes](macos/README.md).

| File | Responsibility |
|---|---|
| `src/main.rs` | Entry point, hidden control window, message loop, menu commands |
| `src/locale.rs` | Simplified Chinese and English menus, and the system-language choice |
| `src/overlay.rs` | One layered window per screen, presented with `UpdateLayeredWindow` |
| `src/texture.rs` | Fractal noise and the four textures |
| `src/tray.rs` | Tray icon and context menu |
| `src/settings.rs` | `%APPDATA%/Sue-Paper/settings.json` |
| `assets/app-icon.png` | Icon artwork |
| `assets/app-icon-64.bgra` | Pixels embedded in the tray icon |
| `assets/sue-paper.ico` | Multi-size icon embedded in the Windows executable |
| `macos/` | AppKit menu bar, overlays, settings, and tests |

## Feedback

Open questions on [GitHub Issues](https://github.com/SueBwj/MattePulp/issues). The source repository is [SueBwj/MattePulp](https://github.com/SueBwj/MattePulp).

## Credits

- The idea of a digital matte surface comes from [Paperman](https://paperman.cc).

## Contributors

- [SueBwj](https://github.com/SueBwj)
- Codex

## License

Source code and documentation in this repository are under the MIT license, `Copyright (c) 2026 SueBwj`. The text is in [LICENSE](LICENSE).

That grant does not cover the screenshots, the app icon, product marks, or other media, and it does not replace the licenses that come with dependencies. `windows`, `serde`, and `serde_json` keep the licenses published with those crates.

Redistribute the copyright notice and the permission notice with the program. The Windows build script places `LICENSE` next to `sue-paper.exe`. The Mac build script places it in the app bundle's `Contents/Resources`.
