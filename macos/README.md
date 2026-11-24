# Native Mac build

The Mac app is a Swift/AppKit menu bar process. `build-macos.sh` runs the existing Rust texture engine to generate all four textures at every intensity from 15% to 30% in 1% steps (64 premultiplied BGRA tiles), then bundles them. There is one texture algorithm, in `src/texture.rs`. The translucent paper artwork supplies the app icon, and the native menu bar uses a readable S in the system text color. The menu itself is either Simplified Chinese or English. A saved `language` value of `zh-Hans` or `en` is reopened from settings; a file with no language follows the system UI language, and anything other than Simplified Chinese uses English. Clicking the intensity row opens a compact nonactivating native slider panel (`IntensityPanel`) spanning 15% to 30% in 1% steps (initial 20%, preserving all four legacy intensities 15/20/25/30). The bundle display name is MattePulp. The executable name stays `Sue-Paper`. The same build copies `LICENSE` into `Contents/Resources`. That MIT text covers repository source and documentation. It does not license the icon, screenshots, or other media.

## Build and run

See the [main README](../README.en.md#macos-apple-silicon) for build and launch instructions. Local execution evidence below is for macOS 26.4.1 only; Intel and universal binaries are not produced.

`CARGO_TARGET_DIR` and `CLANG_MODULE_CACHE_PATH` can point to reusable build caches. The build applies only an ad-hoc integrity signature, verified with `codesign --verify --strict`. It does not use a signing identity, request certificates, notarize, publish, install to Applications, or add a login item. Downloaded copies may be blocked by Gatekeeper; this build does not bypass that protection. A distributable Developer ID/notarization process is separate work.

Settings are atomically written. If they cannot be loaded, defaults are used with a menu error. A failed save leaves the current settings in effect and reports the failure in the menu. A file lock prevents two instances sharing the same settings directory. Snooze is intentionally session-only.

For a short launch/exit check without writing normal user settings:

```sh
scratch=$(mktemp -d)
/tmp/mattepulp-build/Sue-Paper.app/Contents/MacOS/Sue-Paper --smoke-test "$scratch"
rm -rf "$scratch"
```

Normal operation needs neither Accessibility nor Screen Recording permission. It uses the frontmost application's identity, never window titles or input contents. There are no accounts, network services or telemetry.

## Display behavior

Each `NSScreen` gets a borderless nonactivating panel covering its full frame in AppKit points, including screens with negative origins. Panels ignore mouse events, cannot become key/main, do not appear in window cycling, and remain below the menu bar. Texture drawing converts points to backing pixels, keeping each source pixel at one physical pixel. AppKit screen-parameter notifications rebuild panels; backing changes redraw the texture. Old panels close after replacements are prepared.

The panels request all Spaces and fullscreen auxiliary behavior, with `canJoinAllApplications` on macOS 13+. Workspace activation, Space changes and wake notifications refresh visibility. These are window-manager requests, not a promise to cover protected video, system security surfaces, every game or every fullscreen implementation. See Apple's [window collection behaviors](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) and [backing coordinate guidance](https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor).

## Validation and limits

`test-macos.sh BUILD_OUTPUT_DIRECTORY` compiles production Swift sources into a behavioral test executable, runs Rust texture tests and lint, then starts and exits the actual packaged app. It keeps settings in a temporary directory. Its only saved images are generated white paper/text bars composited with the texture, under `BUILD_OUTPUT_DIRECTORY/test-results`; it never captures the desktop or other windows.

Observed on an Apple Silicon Mac running macOS 26.4.1, Swift 6.3.3 and Rust 1.100.0:

- Native arm64 app build, menu bar creation, launch and termination passed.
- All 64 texture/intensity combinations (4 textures x 16 levels) loaded; intensity increases opacity monotonically. Offscreen 1x and 2x rendering produced identical physical pixels and repeated seamlessly.
- Real display frame was 1470 × 956 points at 2x backing scale. Overlay frame matched it; the synthetic fixture retained keyboard focus.
- Native menu actions changed enabled state, texture and intensity and persisted them. Clicking the intensity row opens a compact nonactivating native slider panel (`IntensityPanel`); process-local key and mouse events (no global input injection) and native accessibility actions drove arrow-key steps, accessibility increment/decrement, and `NSSlider` drag tracking across endpoints (15% and 30%) and interior values (17%) - each drag tick previewed from preloaded tiles without touching storage, mouse release and each keyboard/accessibility adjustment saved immediately, cancellation and storage failures reverted overlays and UI to the persisted value, hidden states (disabled, snoozed, excluded) stayed hidden during adjustment, and persisted interior values survived restart. Defaults, normalization (including the full 15...30 range and legacy values), corrupt settings, atomic replacement, duplicate-instance refusal and restart were exercised.
- Snooze hid immediately; timer expiry and explicit resume restored overlays. Exclusion of the actual frontmost synthetic test process hid overlays on startup; clearing the exclusion and restarting restored them.
- A second task-owned synthetic process exercised exclude/include menu actions and real foreground switches. Activation notifications hid the overlay when the excluded fixture came forward and restored it when switching back. Tests wait for asynchronous notification handling, and production uses the notification's activated-app identity.
- Posting the AppKit display-change notification rebuilt the current one-display topology and closed old overlays. This is not physical hot-plug evidence.
- A synthetic native fullscreen window entered a separate Space; overlay visibility and active-Space membership stayed true and the fixture retained focus. Returning from fullscreen and cleanup passed. If a runner cannot enter fullscreen, the test prints a `LIMIT` instead of claiming that observation.

Still requiring hardware/manual checks: external monitor connect/disconnect, multiple displays with mixed scaling or negative origins, independent desktop switching and Stage Manager, fullscreen in unrelated applications, and physical pointer/keyboard interaction through the overlay. Input transparency is configured and checked through the native panel properties and focus observations; the test does not inject global input. No desktop screenshot, private window-title enumeration, system permission change or Windows runtime test was performed locally. Windows all-target checking passed using `cargo check --locked --all-targets --target x86_64-pc-windows-gnu`; native Windows build/tests are included in the Checks workflow for validation on a Windows runner.
