# SafeGPU

A lightweight native macOS utility (pure Swift + AppKit, zero Chromium/Metal overhead) designed for Hackintosh systems without working GPU acceleration. SafeGPU helps prevent glitches, black screens, and WindowServer freezes in Chromium, Electron, CEF, and QtWebEngine applications.

## Features

- **Automatic App Detection + Manual Add:** Scans `/Applications` and `~/Applications` for Electron, Chromium, CEF, and QtWebEngine apps, plus supports adding any `.app` bundle manually via file picker or drag & drop.
- **Hybrid Protection (Manual Control per App):**
  - **Config Patch:** Disables hardware acceleration natively in supported app configs so apps can be opened normally from Dock, Spotlight, and external links:
    - Chromium browsers (Chrome, Brave, Edge, Vivaldi, Opera, Arc, Chromium) via macOS `defaults` (`HardwareAccelerationModeEnabled`) + `Local State`
    - Discord (Stable / PTB / Canary) via `settings.json`
    - VS Code, VS Code Insiders, VSCodium, Cursor, Windsurf, and Antigravity via `argv.json` (JSONC-aware)
    - Slack (`local-settings.json`) and Spotify (`prefs`)
  - **Wrapper `.app` Generator:** Creates `<AppName> (Safe).app` shortcuts with a badged icon in `~/Applications/SafeLaunch` (customizable in Settings), indexed by Spotlight and pinnable to the Dock.
- **Ready-to-Use GPU Flag Presets per App:**
  - **Standard:** `--disable-gpu`
  - **Strict (No Compositing):** `--disable-gpu --disable-gpu-compositing`
  - **SwiftShader (Software WebGL):** `--disable-gpu --use-gl=angle --use-angle=swiftshader --enable-unsafe-swiftshader`
- **Direct Safe Launch:** Test or launch any app immediately with its selected preset, with automatic prompts if the app is already running.
- **Zero Background Overhead:** Runs purely on demand. Closing the main window exits cleanly and removes the temporary Menu Bar quick-launch icon.

## Building & Installing

Requires macOS 13+ and Swift 6+ (Xcode Command Line Tools are sufficient; full Xcode is not required).

```bash
# Run unit tests
swift test

# Build dist/SafeGPU.app
./scripts/build-app.sh

# Build and install to ~/Applications/SafeGPU.app
./scripts/build-app.sh --install
```
