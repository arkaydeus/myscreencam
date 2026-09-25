# MyScreenArt (native)

A native macOS screen recorder and editor. It records the screen, system audio, microphone, webcam and pointer events, then edits (cuts, zooms, webcam overlay, blur, cursor styling, backgrounds) and exports with hardware codecs. It rewrites an unreleased Electron + Rust + FFmpeg app; the plan and rationale are in `docs/native-rewrite-plan.md`.

**Primary goal: high performance, low resource use.** Frames stay in IOSurface-backed `CVPixelBuffer`s end to end. Encoding and decoding go through VideoToolbox/AVFoundation. Compositing uses Core Image on Metal. Nothing polls.

## Stack
- Swift 6 (strict concurrency). The app target defaults to `MainActor` isolation; the engine packages don't.
- SwiftUI for the shell and panels. AppKit where SwiftUI costs too much (timeline, HUD panel, hotkeys).
- ScreenCaptureKit, AVFoundation, VideoToolbox, Core Image, Metal, Core Audio, ImageIO. The only planned third-party dependency is Sparkle (phase 6).
- Minimum macOS 15. Built with Xcode 27 (`/Applications/Xcode.app`).
- XcodeGen generates `MyScreenArt.xcodeproj` from `project.yml`. **The project is not committed**; edit `project.yml`, never the pbxproj.
- mise pins tools and runs every task.

## Layout
```
App/                         app target (SwiftUI/AppKit), Info.plist, entitlements
Packages/MyScreenArtKit/     engine SwiftPM package (testable with `swift test`)
  Sources/MyScreenArtCore    paths, flavor, logging/signposts
project.yml                  XcodeGen spec (bundle IDs, signing, settings)
scripts/dev/                 run.sh (LaunchServices launch), doctor.sh
scripts/perf/                sample.py (CPU/memory sampler), legacy baseline driver
docs/                        plan, perf baseline
```
Engine modules are added as their phase starts. The layering is in the comment at the top of `Packages/MyScreenArtKit/Package.swift`. A module may only depend on modules above it.

## Areas and contracts
- **The shared contract is `ProjectKit`'s model** (`RecordingMeta`, `EditConfig`, `InputEvent`, `CursorIndex`, `RecordingPackage`).
  - All effect times are session (source) seconds.
  - Normalised coordinates are 0…1 with the origin top-left, y down.
  - Change the model only when it's genuinely needed, and update every user of it.
- **App areas** each own one directory under `App/Sources/`:
  - `Recorder/`: `RecordingController`, recorder window, HUD, menu-bar content, region overlay.
  - `Editor/`: `EditorSessions`, editor window, preview, timeline, panels.
  - `Library/`: the library window.
  - `Export/`: `ExportCenter`, `ExportSheet`.
  - `Shell/`: `AppRouter`, app delegate, commands, URL scheme, intents, updates, settings.
- **Cross-area calls** go only through the documented skeleton APIs: `AppModel`, `AppRouter`, `RecordingController.state/isActive/stop/togglePause`, `ExportCenter.isExporting/cancelAll/waitUntilIdle`, `EditorSessions.hasPendingSaves/flushAll`, `ExportSheet(package:edit:)`, `EditorWindow(packageURL:)`.
- **Legacy behaviour and defaults** are specified in `docs/legacy-inventory.md`, including the bugs not to copy.
- **GPU work uses Core Image** (on Metal) and built-in CI filters. Don't add `.metal` files: SwiftPM command-line builds don't compile them. If a custom kernel is unavoidable, compile Metal source at runtime with `MTLDevice.makeLibrary(source:options:)`.

## Tasks
```bash
mise install            # once: installs XcodeGen
mise run build          # generate project + Debug build (signed, Apple Development)
mise run run            # build + launch this worktree's app via LaunchServices
mise run test           # engine package tests (Swift Testing)
mise run lint           # swift-format lint --strict (CI gate)
mise run format         # swift-format in place
mise run doctor         # toolchain/signing/build diagnostics
mise run perf:sample -- --match 'MyScreenArt Dev.app/Contents/MacOS' --duration 60
mise run clean
```
mise sets `DEVELOPER_DIR` to full Xcode, because `xcode-select` on this machine points at the Command Line Tools. Don't run `sudo xcode-select`.

## Builds, identity and permissions
- Debug: product **MyScreenArt Dev**, bundle ID `com.myscreenart.app.dev`, URL scheme `myscreenart-dev`, signed with the stable `Apple Development` identity (team `QWD87G9T3P`). TCC grants therefore survive rebuilds and are shared by all worktrees.
- Release: product **MyScreenArt**, `com.myscreenart.app`, scheme `myscreenart`, `Developer ID Application`.
- Always launch through `mise run run` (it uses `open`). If the app is started from a terminal, TCC charges the terminal instead of the app.
- Recordings: release uses `~/Movies/MyScreenArt/`. `mise run run` sets `MYSCREENART_RECORDINGS_DIR=~/Movies/MyScreenArt Dev/<worktree-hash>/`, so worktrees don't share data.

## Conventions
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`). Put pure logic (time mapping, easing, layout, config decoding) in engine modules and test it there.
- Logging: `Log.*` (`os.Logger`, subsystem = bundle ID). Wrap hot paths (capture, append, composite, encode) in `Log.signposter` intervals so Instruments can measure them.
- No polling or timers for state that has a notification or callback. Nothing may re-render SwiftUI per frame: playhead, meters and timers drive CALayers directly.
- Media stays on the GPU: no `CVPixelBufferLockBaseAddress` copies in hot paths.
- Measure before and after perf-sensitive changes with `scripts/perf/sample.py`, and record the results in `docs/perf-baseline.md`.
