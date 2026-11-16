# Sue-Paper

[中文](README.md) | **English**

**Make your screen feel like paper.**

Sue-Paper lays a procedurally generated paper texture over your entire screen, softening harsh highlights and contrast, turning your emissive display into a "digital matte paper". The portable Windows app uses Rust + raw Win32. The native Apple Silicon Mac app uses AppKit and the same Rust-generated textures.

<p align="center">
  <img src="assets/showcase1.png" width="32%" alt="Reading showcase 1">
  <img src="assets/showcase2.png" width="32%" alt="Reading showcase 2">
  <img src="assets/showcase3.png" width="32%" alt="Reading showcase 3">
</p>

## How It Works

Lightweight, and designed to stay out of your way.

- **An invisible sheet of paper.** The overlay runs above all your windows, across every monitor. Your cursor and keystrokes pass straight through — it never takes focus, never shows up in Alt-Tab. You won't notice it's there; you'll just see paper.
- **Pick your paper.** 4 procedurally generated textures (fractal noise, seamlessly tiled, grain stays crisp at any resolution), with 4 intensity levels: 15% / 20% / 25% / 30%.
- **It steps aside on its own.** Add image viewers, editors or video players to the exclusion list and the texture hides itself whenever they come to the front. Or snooze it for 5 / 15 minutes whenever you want a clean screen.

## Four Textures

![Four textures](showcase/textures.png)

| Texture | Feel |
|---|---|
| Classic Matte | A clean, soft matte finish — for focused reading |
| Whisper Weave | A delicate fabric grain that softens bright apps |
| Sunbaked Parchment | A warm amber, heavy grain — for late-night writing |
| Vellum Mist | A translucent haze — for long reading sessions |

## Download & Usage

**Windows:** Grab the zip from [Releases](https://github.com/SueBwj/sue-paper/releases), extract and run `sue-paper.exe`. That's it. The existing v0.1.0 Windows release is unchanged.

Everything lives in the system tray right-click menu: on/off, texture, intensity, snooze, exclude the current foreground app, quit. Settings are persisted to `%APPDATA%/Sue-Paper/settings.json`.

Windows footprint: ~22–27 MB of memory and 0% CPU at runtime (static texture, updated only when you change it). Multi-monitor support included; overlays rebuild automatically on display changes.

**macOS:** Build `Sue-Paper.app` using the instructions below, then open it and click **S** in the menu bar. The menu has on/off, the same four textures and strengths, 5/15-minute snooze, immediate resume, exclusion of the frontmost app (click again to include it), and quit. Settings live in `~/Library/Application Support/Sue-Paper/settings.json`; exclusions use bundle identifiers, with executable URLs as a fallback. The app requires no Accessibility or Screen Recording permission.

The Mac package is a local Apple Silicon build, not a published or notarized release. See [Mac build and validation notes](macos/README.md) for the tested environment and remaining display/Spaces limitations.

## Build

### macOS (Apple Silicon)

Requires Rust stable and Xcode 16 or newer with Swift 6 and `swift-format` available through `xcrun`:

```sh
./build-macos.sh /tmp/sue-paper-build
./test-macos.sh /tmp/sue-paper-build
open /tmp/sue-paper-build/Sue-Paper.app
```

Use a fresh output directory for each build. Output includes `Sue-Paper.app` and `sue-paper-macos-arm64.zip`. Build tools are only needed to build; the app has no Rust runtime dependency. Quit from the **S** menu. Tests use temporary settings and synthetic windows, briefly entering fullscreen, then close them. They never capture the desktop.

### Windows

Requires a Rust stable toolchain (`stable-x86_64-pc-windows-gnu` or MSVC both work):

```sh
./build-release.ps1
# Output: target/release/sue-paper.exe
```

The script builds the program, then embeds the multi-size `S` logo into the EXE's Windows icon resources, so the tray, File Explorer, shortcuts and Start Menu all show the app icon.

Quality checks:

```sh
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
```

Note: the `windows` crate is pinned to 0.58 (which uses `windows-targets` prebuilt import libraries).
0.60+ switched to `windows-link`, which invokes dlltool at build time to generate import libraries and needs extra PATH setup on the GNU toolchain — hence not adopted.

## Project Layout

| File | Responsibility |
|---|---|
| `src/main.rs` | Entry point, hidden control window, message loop, timer scheduling, menu command dispatch |
| `src/overlay.rs` | Layered overlay windows (one per monitor) + `UpdateLayeredWindow` presentation |
| `src/texture.rs` | Fractal noise texture generation + 4 presets |
| `src/tray.rs` | Tray icon + context menu |
| `src/exclusion.rs` | Foreground process detection (app exclusion) |
| `src/monitor.rs` | Monitor enumeration |
| `src/settings.rs` | JSON settings persistence |
| `assets/logo-s.png` | Original logo artwork (the letter S) |
| `assets/logo-s-64.bgra` | Tray icon pixel data embedded at compile time |
| `assets/sue-paper.ico` | Multi-size Windows icon for File Explorer and Start Menu |
| `src/bin/embed_icon.rs` | Resource tool that writes the ICO into the release EXE |
| `src/bin/export_textures.rs` | Exports the shared texture engine's 16 tiles for the Mac bundle |
| `macos/` | Native AppKit menu bar, overlays, settings and behavioral tests |
| `build-macos.sh`, `test-macos.sh` | Apple Silicon packaging and validation |

## Credits

- Inspired by [Paperman](https://paperman.cc) — the pioneer of the digital matte surface.
- This project is a product of **Vibe Coding**: every line of code, from idea to release, was written through human–AI pair programming — iterating fast, by feel, refining while using it.

## Not Yet Implemented (Future Iterations)

- Circadian rhythm / scheduled auto-toggle
- Launch at login, per-monitor enablement
