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
QuickLookThumbnail/          Quick Look thumbnail extension for .msarec packages (embedded in the app)
Packages/MyScreenArtKit/     engine SwiftPM package (testable with `swift test`)
  Sources/MyScreenArtCore    paths, flavor, logging/signposts, URL-command parsing, shell policies
project.yml                  XcodeGen spec (bundle IDs, signing, settings, Sparkle package)
scripts/dev/                 run.sh (LaunchServices launch), doctor.sh
scripts/perf/                sample.py (CPU/memory sampler), legacy baseline driver
scripts/release/             release.sh (archive → notarise → DMG → appcast), ExportOptions.plist
docs/                        plan, perf baseline, release.md
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
- **Shell hooks for other areas** (`App/Sources/Shell/`):
  - **Export… (⌘E)** is driven by the focused-scene value `\.exportAction: (() -> Void)?` (declared in `Shell/AppCommands.swift`). The editor window publishes it with `.focusedSceneValue(\.exportAction) { showExport = true }`; the menu item is disabled when no focused scene sets it.
  - Opening windows: `AppRouter.showLibrary()`, `showRecorder(source:)` (sets `recorderSourceRequest`, which the recorder reads when it opens), `openEditor(for:)`. Requests made before any scene has appeared are queued and replayed once `bindRouter` binds `openWindowAction`. Every root scene view must use `.bindRouter(model.router)`.
  - Menus, the Dock menu, global hotkeys (⌥⌘↩ recorder, ⌥⇧⌘R finish), the URL scheme and App Intents all go through `ShellActions`. That type calls only `AppRouter` and `RecordingController.state/isActive/stop()/togglePause()`. Finish Recording ⇧⌘R and Pause/Resume ⌥⇧⌘P are enabled from `RecordingController.state`.
  - Quit: `AppDelegate.applicationShouldTerminate` guards on `recording.isActive` (awaits `stop()`) and `exports.isExporting` (`cancelAll()` / `waitUntilIdle()`), and always calls `editors.flushAll()` before quitting. Sparkle postpones an update's relaunch while `AppModel.isBusy`.
  - App Intents get the `AppModel` from `AppDependencyManager` (registered in `MyScreenArtApp.init`) via `@Dependency`.
  - URL scheme `myscreenart://` (Debug `myscreenart-dev://`): `AppURLCommand.parse` in MyScreenArtCore (`record|new-recording`, `display|window|region` or the `record-*` forms, `projects|show-projects|library`, `stop|finish`).
  - Documents: the app exports the UTType `com.myscreenart.recording` (`.msarec`, a package), so double-clicking a recording opens it in the editor.
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
mise run release:dmg    # local Developer ID build + DMG (no notarisation / appcast)
mise run release        # full release pipeline; see docs/release.md
mise run clean
```
mise sets `DEVELOPER_DIR` to full Xcode, because `xcode-select` on this machine points at the Command Line Tools. Don't run `sudo xcode-select`.

## Builds, identity and permissions
- Debug: product **MyScreenArt Dev**, bundle ID `com.myscreenart.app.dev`, URL scheme `myscreenart-dev`, signed with the stable `Apple Development` identity (team `QWD87G9T3P`). TCC grants therefore survive rebuilds and are shared by all worktrees.
- Release: product **MyScreenArt**, `com.myscreenart.app`, scheme `myscreenart`, `Developer ID Application`, arm64 only. Notarised DMG + Sparkle appcast via `scripts/release/release.sh` / `.github/workflows/release.yml` (see `docs/release.md`).
- The Quick Look extension is `<app id>.thumbnail`. It is sandboxed (required for Quick Look extensions) and signed with the app's identity.
- Sparkle stays off until `SPARKLE_PUBLIC_ED_KEY` in `project.yml` holds a real key; Debug builds never check automatically.
- Always launch through `mise run run` (it uses `open`). If the app is started from a terminal, TCC charges the terminal instead of the app.
- Recordings: release uses `~/Movies/MyScreenArt/`. `mise run run` sets `MYSCREENART_RECORDINGS_DIR=~/Movies/MyScreenArt Dev/<worktree-hash>/`, so worktrees don't share data.

## Conventions
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`). Put pure logic (time mapping, easing, layout, config decoding) in engine modules and test it there.
- Logging: `Log.*` (`os.Logger`, subsystem = bundle ID). Wrap hot paths (capture, append, composite, encode) in `Log.signposter` intervals so Instruments can measure them.
- No polling or timers for state that has a notification or callback. Nothing may re-render SwiftUI per frame: playhead, meters and timers drive CALayers directly.
- Media stays on the GPU: no `CVPixelBufferLockBaseAddress` copies in hot paths.
- Measure before and after perf-sensitive changes with `scripts/perf/sample.py`, and record the results in `docs/perf-baseline.md`.
