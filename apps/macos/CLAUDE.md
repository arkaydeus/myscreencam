# My Screen Cam (native macOS app)

This is `apps/macos` in the My Screen Cam monorepo (see the root `CLAUDE.md`). Paths in this file and in `docs/` are relative to `apps/macos`.

A native macOS screen recorder and editor. It records the screen, system audio, microphone, webcam and pointer events, then edits (cuts, zooms, webcam overlay, blur, cursor styling, backgrounds) and exports with hardware codecs. It rewrites an unreleased Electron + Rust + FFmpeg app; the plan and rationale are in `docs/native-rewrite-plan.md`.

**Primary goal: high performance, low resource use.** Frames stay in IOSurface-backed `CVPixelBuffer`s end to end. Encoding and decoding go through VideoToolbox/AVFoundation. Compositing uses Core Image on Metal. Nothing polls.

## Stack
- Swift 6 (strict concurrency). The app target defaults to `MainActor` isolation; the engine packages don't.
- SwiftUI for the shell and panels. AppKit where SwiftUI costs too much (timeline, HUD panel, hotkeys).
- ScreenCaptureKit, AVFoundation, VideoToolbox, Core Image, Metal, Core Audio, ImageIO. Third-party dependencies: Sparkle, plus the speech recognisers (FluidAudio, MLX Audio Swift and their dependencies), which only the `MyScreenCamSpeech` XPC service links (see `docs/subtitles-plan.md`).
- Minimum macOS 15. Built with Xcode 27 (`/Applications/Xcode.app`).
- XcodeGen generates `MyScreenCam.xcodeproj` from `project.yml`. **The project is not committed**; edit `project.yml`, never the pbxproj.
- mise pins tools and runs every task.

## Layout
```
App/                         app target (SwiftUI/AppKit), Info.plist, entitlements
  Resources/AppIcon.icon     app icon (Icon Composer; actool also emits the pre-Tahoe AppIcon.icns)
QuickLookThumbnail/          Quick Look thumbnail extension for .mscam packages (embedded in the app)
SpeechService/               MyScreenCamSpeech.xpc: on-device speech recognition (the one owner of loaded models)
Packages/MyScreenCamKit/     engine SwiftPM package (testable with `swift test`)
  Sources/MyScreenCamCore    paths, flavor, logging/signposts, URL-command parsing, shell policies
  Sources/SpeechCore         speech-model catalogue/downloads, audio preparation, worker protocol, transcript pipeline
Packages/SpeechEngines/      Parakeet (FluidAudio) and Qwen (MLX) adapters + `speech-tool`; build with xcodebuild only
project.yml                  XcodeGen spec (bundle IDs, signing, settings, Sparkle package)
scripts/dev/                 run.sh (LaunchServices launch), doctor.sh, xcodebuild.sh + unregister-builds.sh (LaunchServices cleanup)
scripts/perf/                sample.py (CPU/memory sampler), legacy baseline driver
scripts/speech/              make-catalogue.py (pinned model manifests), timing fixtures and reports
scripts/release/             release.sh (archive → notarise → DMG → appcast), ExportOptions.plist
docs/                        plan, perf baseline, release.md
```
Engine modules are added as their phase starts. The layering is in the comment at the top of `Packages/MyScreenCamKit/Package.swift`. A module may only depend on modules above it.

## Areas and contracts
- **The shared contract is `ProjectKit`'s model** (`RecordingMeta`, `EditConfig`, `InputEvent`, `CursorIndex`, `RecordingPackage`, `TranscriptRevision`).
  - Subtitles live in `EditConfig.subtitles` (style, placement, cues in source seconds). Immutable transcripts are `transcripts/<id>.json` in the package; `cache/transcription/` holds prepared audio and per-window checkpoints (derived, safe to delete).
  - All effect times are session (source) seconds.
  - Normalised coordinates are 0…1 with the origin top-left, y down.
  - Change the model only when it's genuinely needed, and update every user of it.
- **App areas** each own one directory under `App/Sources/`:
  - `Recorder/`: `RecordingController`, recorder window, HUD, menu-bar content, region overlay.
  - `Editor/`: `EditorSessions`, editor window, preview, timeline, panels, and the defaults for new recordings (`ProjectDefaultsStore`, persisted in `UserDefaults`; ProjectKit's `ProjectDefaults` applies them in `EditConfig.makeInitial`).
  - `Library/`: the library window.
  - `Export/`: `ExportCenter`, `ExportSheet`.
  - `Transcription/`: `TranscriptionCenter` (the one transcription queue and speech-service owner), `SpeechModels` (downloads), `SpeechSettings`, the XPC client, Settings › Subtitles.
  - `Shell/`: `AppRouter`, app delegate, commands, URL scheme, intents, updates, settings.
  - `Theme/`: `AppTheme` (shared, not an area): colour tokens, `ThemeButtonStyle`/`ThemeIconButtonStyle`, `ThemeGroupBoxStyle`, `themePanel()`. Every window and sheet root applies `.themedWindow()`; the app is always dark.
- **Cross-area calls** go only through the documented skeleton APIs: `AppModel`, `AppRouter`, `RecordingController.state/isActive/stop/togglePause`, `ExportCenter.isExporting/cancelAll/waitUntilIdle`, `EditorSessions.hasPendingSaves/flushAll/isAnyPlaying/session(for:)`, `EditorModel.receiveTranscript(_:)` (transcription commits through an open editor), `TranscriptionCenter.job(for:)/transcribe/cancel/cancelAll/isAvailable/retime`, `ExportSheet(package:edit:)`, `EditorWindow(packageURL:)`, `ProjectDefaultsStore.load()` (the defaults a recording's first edit is built from), `DefaultsSettingsView` (Settings › Defaults).
- **Shell hooks for other areas** (`App/Sources/Shell/`):
  - **Export… (⌘E)** is driven by the focused-scene value `\.exportAction: (() -> Void)?` (declared in `Shell/AppCommands.swift`). The editor window publishes it with `.focusedSceneValue(\.exportAction) { showExport = true }`; the menu item is disabled when no focused scene sets it.
  - Opening windows: `AppRouter.showLibrary()`, `showRecorder(source:)` (sets `recorderSourceRequest`, which the recorder reads when it opens), `openEditor(for:)`. Requests made before any scene has appeared are queued and replayed once `bindRouter` binds `openWindowAction`. Every root scene view must use `.bindRouter(model.router)`.
  - Menus, the Dock menu, global hotkeys (⌥⌘↩ recorder, ⌥⇧⌘R finish), the URL scheme and App Intents all go through `ShellActions`. That type calls only `AppRouter` and `RecordingController.state/isActive/stop()/togglePause()`. Finish Recording ⇧⌘R and Pause/Resume ⌥⇧⌘P are enabled from `RecordingController.state`.
  - Quit: `AppDelegate.applicationShouldTerminate` guards on `recording.isActive` (awaits `stop()`) and `exports.isExporting` (`cancelAll()` / `waitUntilIdle()`), and always calls `editors.flushAll()` before quitting. Sparkle postpones an update's relaunch while `AppModel.isBusy`.
  - App Intents get the `AppModel` from `AppDependencyManager` (registered in `MyScreenCamApp.init`) via `@Dependency`.
  - URL scheme `myscreencam://` (Debug `myscreencam-dev://`): `AppURLCommand.parse` in MyScreenCamCore (`record|new-recording`, `display|window|region` or the `record-*` forms, `projects|show-projects|library`, `stop|finish`).
  - Documents: the app exports the UTType `com.myscreencam.recording` (`.mscam`, a package), so double-clicking a recording opens it in the editor.
- **Legacy behaviour and defaults** are specified in `docs/legacy-inventory.md`, including the bugs not to copy.
- **Speech** runs only in `MyScreenCamSpeech.xpc` (it exits when released, returning model memory). Models download only after the user picks an engine in Settings › Subtitles; the worker loads them only from verified directories under `~/Library/Application Support/<app id>/Models`. SDK facts, pins, measurements and limitations: `docs/speech-integration.md`.
- **GPU work uses Core Image** (on Metal) and built-in CI filters. Don't add `.metal` files: SwiftPM command-line builds don't compile them. If a custom kernel is unavoidable, compile Metal source at runtime with `MTLDevice.makeLibrary(source:options:)`.

## Tasks
Run these from `apps/macos` (or anywhere inside it). From elsewhere in the repo use `mise //apps/macos:<task>`.
```bash
mise install            # once: installs XcodeGen (or `mise run setup` at the repo root for everything)
mise run build          # generate project + Debug build (signed, Apple Development)
mise run run            # build + launch this worktree's app via LaunchServices
mise run test           # engine package tests (Swift Testing)
mise run test:speech-engines # speech worker path and token-mapping tests
mise run lint           # swift-format lint --strict
mise run check          # lint + test + build: the local gate before pushing (no GitHub CI)
mise run format         # swift-format in place
mise run doctor         # toolchain/signing/build diagnostics
mise run perf:sample -- --match 'My Screen Cam Dev.app/Contents/MacOS' --duration 60
mise run release:dmg    # local Developer ID build + DMG (no notarisation / appcast)
mise run install        # Developer ID Release build installed to /Applications (-- --open to launch)
mise run release        # full release pipeline; see docs/release.md
mise run clean          # also unregisters stale builds
mise run unregister     # unregister stale My Screen Cam builds from every worktree
mise run build:perf     # optimised Dev build (same bundle ID/TCC) for measurements
```
Engine benchmarks without the app: `swift build -c release --product msc-tool` (in `Packages/MyScreenCamKit`), then:
- `msc-tool import-legacy <old Recording_…> <dir>` wraps an old-app recording as a `.mscam`.
- `msc-tool export <pkg> <out> [--format hevc|h264|prores|gif] [--fps] [--scale] [--raw]` benchmarks an export.
- `msc-tool play <pkg> [--seconds N] [--size WxH]` is a headless editor-playback benchmark.

`scripts/dev/make-sample-recording.swift <dir>` creates a synthetic `.mscam`.
mise sets `DEVELOPER_DIR` to full Xcode, because `xcode-select` on this machine points at the Command Line Tools. Don't run `sudo xcode-select`.
Building the speech service needs Xcode's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`; `mise run doctor` checks). The xcodebuild tasks pass `$MSC_XCODEBUILD_TRUST` (`-skipPackagePluginValidation -skipMacroValidation`) for mlx-swift's build plugin and swift-syntax macros from the pinned `Package.resolved`.

## Builds, identity and permissions
- Debug: product **My Screen Cam Dev**, bundle ID `com.myscreencam.app.dev`, URL scheme `myscreencam-dev`, signed with the stable `Apple Development` identity (team `QWD87G9T3P`). TCC grants therefore survive rebuilds and are shared by all worktrees.
- Release: product **My Screen Cam**, `com.myscreencam.app`, scheme `myscreencam`, `Developer ID Application`, arm64 only. Built, notarised and published locally with `scripts/release/release.sh` (`mise run release:publish`) as GitHub Releases of this public repo, `arkaydeus/myscreencam` (see `docs/release.md`).
- The Quick Look extension is `<app id>.thumbnail`. It is sandboxed (required for Quick Look extensions) and signed with the app's identity.
- xcodebuild registers every app it builds with LaunchServices, and there's no setting to turn that off. Left alone, every worktree adds another "My Screen Cam Dev" Quick Look entry to Login Items & Extensions. So the xcodebuild tasks go through `scripts/dev/xcodebuild.sh`, and `release.sh` has an exit trap. Both run `unregister-builds.sh`, which unregisters, across all worktrees, every My Screen Cam bundle that is gone or is an idle build product. Running apps and installed copies are kept. `run.sh` registers the app it launches. If you run xcodebuild on the app scheme by hand, use the wrapper or run `mise run unregister` afterwards.
- Sparkle stays off until `SPARKLE_PUBLIC_ED_KEY` in `project.yml` holds a real key; Debug builds never check automatically.
- Always launch through `mise run run` (it uses `open`). If the app is started from a terminal, TCC charges the terminal instead of the app.
- Recordings: release uses `~/Movies/My Screen Cam/`. `mise run run` sets `MYSCREENCAM_RECORDINGS_DIR=~/Movies/My Screen Cam Dev/<worktree-hash>/`, so worktrees don't share data.

## Checks and CI
No GitHub CI: macOS runners are too expensive for this project. Run `mise run check` locally before pushing or opening a PR. Releases are also built locally (`docs/release.md`).

## Conventions
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`). Put pure logic (time mapping, easing, layout, config decoding) in engine modules and test it there.
- Logging: `Log.*` (`os.Logger`, subsystem = bundle ID). Wrap hot paths (capture, append, composite, encode) in `Log.signposter` intervals so Instruments can measure them.
- No polling or timers for state that has a notification or callback. Nothing may re-render SwiftUI per frame: playhead, meters and timers drive CALayers directly.
- Media stays on the GPU: no `CVPixelBufferLockBaseAddress` copies in hot paths.
- Measure before and after perf-sensitive changes with `scripts/perf/sample.py`, and record the results in `docs/perf-baseline.md`.
