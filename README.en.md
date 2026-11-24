# MattePulp

[中文](README.md) | **English**

<p align="center">
  <img src="assets/app-icon.png" width="128" alt="MattePulp icon: two overlapping translucent sheets on a dark blue field">
</p>

**MattePulp covers the screen with a generated paper texture so a bright display reads like matte paper.**

The Chinese name is 柔纸. The repository, the Windows executable, and the Mac bundle stay named sue-paper, so existing download URLs, settings folders, and texture ids stay put. The Windows app is a portable tray program. The Mac app is a native Apple Silicon menu-bar program. Both use the same texture engine.

<p align="center">
  <img src="assets/showcase1.png" width="32%" alt="Paper grain over a reading page. The page is third-party writing.">
  <img src="assets/showcase2.png" width="32%" alt="The same reading page with a highlighted passage. Those words are not part of MattePulp.">
  <img src="assets/showcase3.png" width="32%" alt="A later page in that reading view, still under the paper grain.">
</p>

The writing in these pictures belongs to its authors. MattePulp adds the grain. It does not claim the words or the reading app.

## Download

Download a published package first. The source changes below are not inside those packages.

| System | Release | File |
|---|---|---|
| Windows x64 | [v0.1.0](https://github.com/SueBwj/sue-paper/releases/tag/v0.1.0) stable | [sue-paper-v0.1.0-windows-x64.zip](https://github.com/SueBwj/sue-paper/releases/download/v0.1.0/sue-paper-v0.1.0-windows-x64.zip) |
| Mac Apple Silicon | [v0.1.1-macos.1](https://github.com/SueBwj/sue-paper/releases/tag/v0.1.1-macos.1) prerelease | [Sue-Paper-macOS-arm64-local-d9fb2c7.dmg](https://github.com/SueBwj/sue-paper/releases/download/v0.1.1-macos.1/Sue-Paper-macOS-arm64-local-d9fb2c7.dmg) |

Windows v0.1.0 is commit `53b266a`. That build is named Sue-Paper, uses the older tray image `assets/logo-s-64.bgra`, and has neither the language menu nor the current translucent paper icon.

The Mac prerelease is commit `d9fb2c7` and is Apple Silicon only. Its disk image already uses the translucent paper icon. Menu items still carry Chinese and English together, it has no separate language choice, and it is not notarized. Gatekeeper may block a downloaded copy.

In this source tree the Windows tray and the Mac menu bar show 柔纸 or MattePulp and each has its own language menu. That interface has no new package yet. The Mac menu-bar mark stays S, and intensity stays on four steps.

## Usage

The texture covers every screen. The pointer and the keyboard pass through it. It does not take focus or appear in window switching. Mac display limits are in the [Mac notes](macos/README.md#display-behavior).

Four textures come from fractal noise and tile without a seam. Windows intensity is still the four steps 15%, 20%, 25%, and 30%. Texture ids in the settings file are unchanged.

| Settings id | English menu | Chinese menu | Character |
|---|---|---|---|
| ClassicMatte | Classic Matte | 经典哑光 | Clean, soft grain for reading |
| WhisperWeave | Whisper Weave | 织物纹理 | A fine weave that softens bright windows |
| Parchment | Sunbaked Parchment | 羊皮纸 | Warm, heavier grain |
| VellumMist | Vellum Mist | 薄纱雾面 | A light haze |

In a Windows build from this source, the Snooze menu adds "Resume now" while snoozing, which ends that snooze immediately. Snooze is not written to settings. When the foreground app is already excluded, the menu offers to include it, and the change takes effect immediately. The v0.1.0 package does not include these two actions.

![Four textures over the same horizontal lines](showcase/textures.png)

**Windows.** Unzip the stable package and run `sue-paper.exe`. When you build this source tree, right-click the tray icon. Each time the menu opens it is rebuilt in one language:

- Enable paper texture
- Texture, Intensity, and Snooze for 5 or 15 minutes
- Exclude the current app. An exclusion is the foreground process file name, such as `photos.exe`
- Language: 中文 or English
- Quit

The tray tip and the hidden window title are 柔纸 in Chinese and MattePulp in English. After you choose a language the tip changes immediately, and the next menu is entirely in that language. The language names stay 中文 and English, so either menu can be used to switch back.

Older settings with no `language` field still load. The menu then follows the Windows UI language. `zh-Hans`, `zh-CN`, `zh-SG`, and `zh-CHS` select Simplified Chinese. Traditional Chinese and every other language select English. A choice is stored as `language` with the value `zh-Hans` or `en`, and the next launch keeps it. The file remains `%APPDATA%\Sue-Paper\settings.json`.

**Mac.** The published disk image still has the mixed-language menu described above. Build `Sue-Paper.app` from this source and click **S** in the menu bar. Each time the menu opens it uses one language: Enable paper texture, Texture, Intensity, Language, Snooze for 5 or 15 minutes, Exclude or Include, and Quit MattePulp. While snoozing, the menu adds "Resume now". Intensity remains 15%, 20%, 25%, and 30%. With no `language` field, the menu follows the system UI language using the same rules as Windows; a choice is stored in the same `language` value. The menu-bar tip and accessibility name switch immediately to 柔纸 or MattePulp, while the visible mark stays S. Exclusions use a bundle identifier, or the executable URL when there is no bundle identifier. The app asks for neither Accessibility nor Screen Recording permission. Settings remain `~/Library/Application Support/Sue-Paper/settings.json`. Finder shows the display name MattePulp, and the executable remains `Sue-Paper`.

## Compatibility

- The published Windows package is 64-bit. An older `settings.json` with no language field still loads. The intensity steps are unchanged.
- The published Mac package is Apple Silicon and needs macOS 12 or newer. v0.1.1-macos.1 is ad-hoc signed and not notarized.
- The bundle identifier remains `com.suebwj.sue-paper`. The Mac executable remains `Sue-Paper`. The Windows executable remains `sue-paper.exe`.
- The running program uses about 22-27 MB of memory. A still texture does not keep using CPU; it is redrawn when you change it. Overlays are rebuilt when the displays change. Those figures describe the existing Windows program.

## Build and test

### Windows

Requires Rust stable (`stable-x86_64-pc-windows-gnu` or MSVC):

```sh
./build-release.ps1
```

The script writes `target/release/sue-paper.exe`, embeds `assets/sue-paper.ico` into the executable's icon resource, and copies the repository `LICENSE` next to the executable. Ship that `LICENSE` with `sue-paper.exe`. Do not archive the whole `target\release` directory. Tray pixels come from `assets/app-icon-64.bgra`, which is embedded at compile time. Those three icon files are the current translucent paper art, not the older art in v0.1.0.

Format, lint, and test on Windows:

```sh
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
```

The `windows` crate stays on 0.58 because that release uses the prebuilt import libraries in `windows-targets`. From 0.60 onward, `windows-link` runs dlltool at build time and needs extra PATH setup on the GNU toolchain, so this project has not moved.

### macOS (Apple Silicon)

Requires macOS 12 or newer, Rust stable, and Xcode 16 or newer, with Swift 6 and `swift-format` available through `xcrun`:

```sh
./build-macos.sh /tmp/sue-paper-build
./test-macos.sh /tmp/sue-paper-build
open /tmp/sue-paper-build/Sue-Paper.app
```

Use a fresh output directory for each build. The outputs are `Sue-Paper.app` and `sue-paper-macos-arm64.zip`. The script places `LICENSE` in `Contents/Resources` before the ad-hoc signature. Running the app does not require Rust. Quit from the **S** menu. Tests use temporary settings and synthetic windows, enter fullscreen briefly, and then close those windows. They do not capture the desktop. The tested environment and the display and Spaces limits are in the [Mac build and validation notes](macos/README.md).

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

Open questions on [GitHub Issues](https://github.com/SueBwj/sue-paper/issues). The source repository is [SueBwj/sue-paper](https://github.com/SueBwj/sue-paper).

## Credits

- The idea of a digital matte surface comes from [Paperman](https://paperman.cc).
- The program was written by SueBwj together with coding assistants.

## License

Source code and documentation in this repository are under the MIT license, `Copyright (c) 2026 SueBwj`. The text is in [LICENSE](LICENSE).

That grant does not cover the screenshots, the app icon, product marks, or other media, and it does not replace the licenses that come with dependencies. `windows`, `serde`, and `serde_json` keep the licenses published with those crates.

Redistribute the copyright notice and the permission notice with the program. The Windows build script places `LICENSE` next to `sue-paper.exe`. The Mac build script places it in the app bundle's `Contents/Resources`.
