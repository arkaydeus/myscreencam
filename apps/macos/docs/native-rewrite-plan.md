# My Screen Cam Native — Rewrite Plan

Status: **phases 0–6 implemented (2026-09-25)**. Engine: ProjectKit, CaptureKit, RecordingKit, RenderKit, ExportKit. App: Recorder, Library, Editor, Export, Shell (Sparkle, Quick Look, App Intents, release pipeline). Live capture awaits permission-based validation (`docs/live-test-checklist.md`). Measurements are in `docs/perf-baseline.md`.
Source app: `/Users/arkaydeus/project/apps/myscreenart` (Electron + React + Rust daemon + FFmpeg). It was never released, so the rewrite needs no compatibility with its files, bundle ID or update feed.

---

## 1. Goal

Rebuild My Screen Cam as a native macOS app that does what the current app does and uses far fewer resources. Wherever the OS provides a hardware-accelerated, zero-copy path, use it instead of a third-party layer.

Guiding rules:

1. **One process, no IPC.** The Electron shell, WebSocket JSON-RPC, auth tokens, daemon lifecycle and reconnect logic all go away.
2. **Frames stay on the GPU.** Every video frame lives in an IOSurface-backed `CVPixelBuffer`, from capture to encode to composite to display. Nothing is copied into `Vec<u8>`, piped through stdin, or read back to the CPU.
3. **Hardware codecs only.** Capture, preview and export all use VideoToolbox through AVFoundation, which runs on the Apple silicon media engines. FFmpeg goes away completely.
4. **Preview and export share one renderer.** The editor preview runs the same Metal/Core Image compositor as export, so what you see is what you get. This removes a whole class of current bugs where preview and export disagree.
5. **Nothing runs when nothing changes.** No polling, and no UI update at display rate unless the display actually needs it.
6. **Minimal dependencies.** Apple frameworks, plus Sparkle for updates.

---

## 2. What we're replacing (findings from the current code)

### 2.1 Capture and recording (Rust daemon)

| Area | Current implementation | Problem |
|---|---|---|
| Screen | ScreenCaptureKit BGRA → each frame copied into `Vec<u8>` → piped to **software libx264 ultrafast** | Heavy CPU; 2+ copies per frame; frames silently dropped when the channel is full |
| Frame rate | Constant-rate output built by re-sending the previous frame | Encodes duplicate frames even when the screen is static |
| Webcam | Spawns `ffmpeg -f avfoundation`, reads raw yuv420p from a pipe, clones each frame, then pipes it into a second x264 ffmpeg | Two extra processes; timestamp is the pipe-read time |
| Mic | cpal, allocates per callback, piped to ffmpeg AAC | Unstable device indices; dropped buffers cause drift (no timestamps) |
| System audio | Hard-coded 48 kHz stereo; ad-hoc interleaving ("probably wrong" comment) | Correctness risk |
| Sync | "First successful send" instant per stream | Approximate |
| Input events | `CGEventTap` listen-only, run loop pumped every 100 ms; the cursor-type monitor polls `NSCursor.currentCursor` every 500 ms | `currentCursor` reports this process's cursor only, so the type is probably always "arrow" |
| Window capture | Checks every 500 ms that the window still exists; window origin captured once | Events are wrong if the window moves |
| Display capture | Excludes nothing | The app's own windows are recorded |

### 2.2 Export (FFmpeg filter graph)

- A single ffmpeg run with a large `filter_complex`, in the order segments → blur → zoom → cursor → webcam, encoded with **software libx264** (`-preset medium`). CRF 0 "lossless" produces H.264 High 4:4:4 Predictive, which QuickTime can't play.
- Rounded webcam corners are drawn per pixel with `geq`, which is very slow and has hard (aliased) alpha edges.
- **Correctness bugs we won't carry over:**
  - Zoom easing is **linear in export** but **easeInOutCubic in preview**.
  - The webcam **isn't cut with the segments**, so it drifts after the first cut.
  - Trim without cuts offsets the cursor by `trim.start`.
  - The cursor is drawn after zoom, so it's in the wrong place while zoomed. The preview has the same bug.
  - The click animation grows from the top-left corner. Click-highlight colour, radius and duration are ignored in export.
  - Webcam size ignores `layout.w` and `aspectRatio`.
  - Blur strength differs: box blur in export vs Gaussian in preview.
  - `amix` normalisation halves the volume when both audio tracks are present.
  - Progress freezes after a ≥15% jump.
  - Captures with an odd pixel dimension (e.g. 2056×1329) **fail to export**, because libx264 requires even sizes. This was confirmed while measuring the baseline.

### 2.3 UI (React renderer)

- Every store read subscribes to the whole store, so **the entire app re-renders at 60 Hz during playback** and at 10 Hz while recording. The keydown listener is re-attached every frame.
- Preview plays 4 separate `<video>`/`<audio>` elements kept in sync by hand (re-seek on >150 ms drift).
- Waveforms decode the whole audio file in the renderer. `Math.max(...peaks)` can overflow the stack on long recordings.
- Project cards load the **full `screen.mov`** as their thumbnail.
- **Time-base bug:** zoom keyframes, blur and cursor are in source time but evaluated against edited time, so they drift after cuts.
- **Missing or broken:**
  - No trim handles.
  - No undo/redo.
  - Toasts never show.
  - ⌘E Export does nothing.
  - ⌘⇧R start isn't wired up.
  - Drag trail and cursor smoothing are saved but never rendered.

---

## 3. Target architecture

```
┌──────────────────────────── My Screen Cam.app (single process) ────────────────────────────┐
│                                                                                           │
│  App layer (SwiftUI + AppKit where needed)                                                │
│   Library · Recorder · Editor · Export sheet · MenuBarExtra · Recording HUD (NSPanel)     │
│   AppKit timeline (CALayer-based) · AVPlayerView/CAMetalLayer preview · Sparkle           │
│                         │  @Observable models, @MainActor                                 │
│  ───────────────────────┼───────────────────────────────────────────────────────────────  │
│  Engine (Swift packages, Swift 6 strict concurrency, actors)                              │
│                                                                                           │
│   CaptureKit     SCStream (screen + system audio + mic) · AVCaptureSession (webcam)       │
│                  CGEventTap listen-only (pointer) · cursor image capture · permissions    │
│   RecordingKit   RecordingSession actor · AVAssetWriter per stream (VideoToolbox HEVC)    │
│                  fragmented MOV for crash safety · events writer · package writer         │
│   ProjectKit     Package model (meta/edit/events Codable) · library · presets             │
│                  thumbnails · waveform peak cache · UndoManager-backed edit store         │
│   RenderKit      Timeline math (segments, source↔edited time) · zoom/cursor/webcam/blur   │
│                  pure functions · AVMutableComposition builder · custom                   │
│                  AVVideoCompositing (Core Image on Metal + custom Metal kernels)          │
│                  · audio mix + MTAudioProcessingTap (gain > 0 dB, metering)               │
│   ExportKit      AVAssetReader(composition) → AVAssetWriter (HEVC/H.264/ProRes)           │
│                  · progress · cancellation · GIF via ImageIO                              │
└───────────────────────────────────────────────────────────────────────────────────────────┘
      ScreenCaptureKit · AVFoundation · VideoToolbox · Core Image · Metal · Core Audio · ImageIO
```

### 3.1 Platform and toolchain

- **Language:** Swift 6.x with strict concurrency; Swift Testing for tests.
- **Minimum macOS: 15 (Sequoia)**, recommended. This version gives us:
  - `SCStream` microphone capture (`captureMicrophone`), so screen, system audio and mic share one clock and one callback path.
  - `SCContentSharingPicker` (the system source picker).
  - `SCScreenshotManager` for still previews.
  - The modern `@Observable` / SwiftUI APIs.
  - On macOS 26, SwiftUI picks up the new system look automatically. See the decisions in §9.
- **UI:**
  - SwiftUI for the app shell, forms and panels. These use native controls: `Slider`, `Picker`, `Toggle`, `ColorPicker`, `Table`/`LazyVGrid`.
  - AppKit for the parts where SwiftUI costs too much: the timeline, the recording HUD panel, and the global hotkey.
- **Build:**
  - Engine modules are a local SwiftPM package, so `swift build` / `swift test` work from the CLI for agents and local checks (no GitHub CI; `mise run check`).
  - The app target is an Xcode project generated from an **XcodeGen `project.yml`**. That keeps it reproducible and avoids `.pbxproj` merge conflicts.
  - `mise` tasks wrap everything (`mise run build|test|run|release`) and set `DEVELOPER_DIR=/Applications/Xcode.app/...`. This machine currently has `xcode-select` pointing at Command Line Tools, and setting `DEVELOPER_DIR` avoids needing sudo.
- **Dependencies:** Sparkle 2 (updates) only. No FFmpeg, no Rust, no Node.

### 3.2 Capture path (zero-copy)

**Screen (`SCStream`):**
- Captured at **native pixel resolution**: `captureResolution = .best`, with width and height = points × `backingScaleFactor`.
- Pixel format `420v` (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`), which the encoder accepts natively, so no colour conversion is needed.
- `minimumFrameInterval` 1/60 (configurable 30/60), `queueDepth` 5.
- `showsCursor = false` when using the custom cursor.
- The **app's own windows are excluded** from the content filter.
- ScreenCaptureKit only delivers frames when content changes. We **keep variable frame rate** in the file (MOV supports it), so a static screen costs almost nothing to encode. Export resamples to constant frame rate through `videoComposition.frameDuration`.

**Writers:**
- Each `CMSampleBuffer` is appended **as-is** to an `AVAssetWriterInput`. The IOSurface goes straight to VideoToolbox with no copy.
- Encoder settings:
  - HEVC, bitrate scaled to resolution × fps.
  - `kVTCompressionPropertyKey_RealTime = true`.
  - `MaximizePowerEfficiency = true` while recording.
  - Maximum keyframe interval of about 1 s, so editor scrubbing stays responsive.
- `movieFragmentInterval` ≈ 2 s, so a crash or power loss still leaves a playable file.

**Audio:**
- System audio and mic come from the same `SCStream` (macOS 15). Buffers keep their real presentation timestamps, so there is no drift from dropped buffers.
- They are written as AAC 48 kHz, or ALAC/PCM as an option if we want lossless intermediates.

**Webcam:**
- `AVCaptureSession` with `AVCaptureVideoDataOutput` in a hardware-friendly format (`420v`), feeding a writer with the same settings.
- Devices are identified by `uniqueID`, which is stable. The old positional indices and name matching go away.
- The preview uses `AVCaptureVideoPreviewLayer`, which is zero-copy and needs no React.

**Clock:**
- Every stream's timestamps are on the **host time clock**:
  - ScreenCaptureKit buffers are already on it.
  - Webcam timestamps come from `AVCaptureSession.synchronizationClock` and are converted to host time.
  - `CGEvent` timestamps are Mach absolute time.
- `meta.json` stores each stream's exact first presentation timestamp relative to the session start, which gives frame-accurate sync without guessing.

**Input events:**
- Listen-only `CGEventTap` on its own run-loop thread. It is event-driven, not pumped.
- Recorded events: move, drag, down/up for each button, and scroll (new, needed for future zoom heuristics).
- Coordinates are normalised to the captured content rect. For window capture we track the window frame, so moving the window during recording is handled.

**Cursor images:**
- Captured with `NSCursor.currentSystemCursor`, sampled at most once per mouse event batch (≤30 Hz) and de-duplicated by image hash.
- Each image is stored in the package as `cursors/<id>.png` with its hotspot and a **classified kind**. The kind (arrow, pointingHand, iBeam, resize…, crosshair, or `other`) comes from matching the image against the standard `NSCursor` set.
- Any system cursor (resize arrows, crosshair, app-specific cursors) renders correctly.
- *This needs a spike in phase 1 to confirm cost and behaviour.*

**Cursor styles in the editor** (the Cursor panel):
- **System** (default): the exact captured images.
- **Stylised**: bundled SVG cursors picked by classified kind. The bundled arrow, pointingHand and iBeam SVGs are extended with resize and crosshair versions; any other kind falls back to the captured image.
- **Fixed**: always one chosen cursor, as with the current `cursorType` override.

Size, smoothing, click highlight, drag trail and hide-when-idle apply to all three styles.

**Power:**
- `ProcessInfo.beginActivity(.userInitiated, .idleSystemSleepDisabled)` while recording or exporting.
- QoS: capture `.userInteractive`, writing `.userInitiated`, thumbnails and waveforms `.utility`.

### 3.3 Render engine (one compositor for preview and export)

**Composition:**
- `CompositionBuilder` turns `(package, EditConfig)` into:
  - an `AVMutableComposition`: screen, webcam, system audio and mic tracks, **each with the same segment cuts** and its own sync offset;
  - an `AVMutableVideoComposition` using a **custom `AVVideoCompositing` class**;
  - an `AVAudioMix`.

**Compositor:**
- Receives source `CVPixelBuffer`s (hardware-decoded, IOSurface) and renders into a pixel buffer from the composition's pool using a `CIContext` backed by a shared `MTLDevice`. Output stays on the GPU.
- Effects, all as pure `f(sourceTime) → params` functions with unit tests:
  - **Zoom:** scale around the target; easeInOutCubic (one implementation); instant keyframes. Mouse-follow mode is implemented properly in a later phase.
  - **Blur regions:** Gaussian (`CIGaussianBlur` + `CIAffineClamp`), cropped to the region. Optional feathered edge.
  - **Webcam:** respects `layout.w/h` and `aspectRatio`; mirroring; **anti-aliased rounded-rect / circle mask via an SDF Metal kernel**; drop shadow; drawn above the zoomed screen.
  - **Cursor:**
    - Positions go through a spring smoothing track, precomputed once when the project loads (none/rapid/medium/slow), then looked up with binary search.
    - Drawn **inside the zoom transform**, so it tracks correctly.
    - Scaled around its hotspot.
    - Click highlight uses colour, radius and duration. Optional drag trail.
- **Time base:** all effect times are stored in **source time**. The compositor maps composition time to source time through the segment map, which fixes the drift-after-cuts bug.

**Preview:**
- `AVPlayer` + `AVPlayerView`/`AVPlayerLayer` driving the same composition. One master clock, hardware decode, and cuts handled by the composition itself; no hand-written drift correction.
- `renderSize` is set to the view's backing size, so the preview doesn't composite at 4K in a small window.
- Rendering pauses when the window is occluded.
- Editing parameters swaps an immutable render-state snapshot in the compositor and re-renders the current frame.

**Audio:**
- `AVAudioMix` volume handles 0 dB and below.
- An `MTAudioProcessingTap` applies gain above 0 dB and feeds the **level meters**. Meter data is published at about 30 Hz to a `CALayer`, not through SwiftUI state.
- Both tracks are summed without the `amix` halving, with a soft limiter to prevent clipping.

**Waveforms:**
- `AVAssetReader` decodes to a peak/RMS pyramid, written once to `cache/waveform-<track>.bin` in the package.
- The timeline draws them as `CAShapeLayer` paths per zoom level.

**Thumbnails:**
- `AVAssetImageGenerator` renders one frame to `cache/thumbnail.heic` when a recording stops. The library never opens the video.
- Optional later: a Quick Look thumbnail extension so packages show previews in Finder.

### 3.4 Export

**Pipeline:**
- `AVAssetReader` reads the composition (with the video composition and audio mix) and feeds `AVAssetWriter`.
- This is chosen over `AVAssetExportSession` because it gives control over bitrate, profile, frame rate, colour tags, progress and cancellation.

**Formats:**
- H.264 (compatibility), HEVC (default), HEVC 10-bit, or ProRes 422 as the high-quality/"lossless" replacement. The M-series media engines accelerate all of them.
- Colour tags are BT.709.
- The file is fast-start / network-optimised.

**Presets:**
- Web (1080p30 H.264), Smooth (60 fps), Compact (24 fps, lower bitrate), and Master (ProRes).
- Optional output scale (100/75/50%).

**Progress and completion:**
- Progress = appended output presentation time / output duration, reported through `AsyncStream` and never frozen.
- Cancellation deletes the partial file.
- A `UserNotifications` banner appears on completion, with a "Show in Finder" action.

**Later:** GIF export through `CGImageDestination`.

### 3.5 App shell

- **Windows:**
  - Library window: a grid of project cards.
  - Recorder: a sheet or panel.
  - Editor: one window per project.
  - The window position is restored natively (`NSWindow` frame autosave).
- **Recording HUD:**
  - A small non-activating `NSPanel` with the timer, stop and cancel, excluded from capture.
  - The `MenuBarExtra` shows the elapsed time and a stop item.
- **Menu bar and Dock:**
  - `MenuBarExtra` with Record Display, Record Window, Stop, Show Library, Quit. The Dock menu has the same items.
  - "Hide Dock icon when idle" is implemented with `NSApp.setActivationPolicy`.
- **Global hotkey:**
  - Carbon `RegisterEventHotKey`, which needs no Accessibility permission.
  - Defaults: ⌥⌘↩ opens a new recording, and ⌘⇧R starts/stops. This fixes the current half-wired shortcut.
- **Automation:**
  - The `myscreencam://` URL scheme is kept (record, display, window, projects).
  - **App Intents** are new: "Start Recording", "Stop Recording", "Open Library". These work from Shortcuts, Spotlight and Siri.
- **Undo, redo and autosave:**
  - `UndoManager` covers every edit, so undo/redo is native.
  - Autosave is a debounced (≈500 ms) atomic write of `edit.json`, also triggered on window close and app termination.
- **Quit guards:**
  - Recording → "Stop recording and quit?"
  - Exporting → "Cancel export and quit / Quit when finished / Keep open"
  - Implemented in `applicationShouldTerminate` returning `.terminateLater`.
- **Permissions:**
  - Screen: `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`.
  - Camera and mic: `AVCaptureDevice.authorizationStatus` / `requestAccess`.
  - Input Monitoring: `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`.
  - Deep links into the matching System Settings pane.
  - Re-checked on `NSApplication.didBecomeActive`, not by polling.
- **Updates:**
  - Sparkle 2 with an EdDSA-signed appcast hosted on GitHub Releases.
  - Update installation is blocked while recording or exporting (Sparkle's `updater(_:shouldPostponeRelaunchForUpdate:)`).
- **Theme:** "Midnight Glass" across every window (navy surfaces, floating panels, green accent), always dark: `NSApp.appearance` is Dark Aqua so menus, alerts and panels match. Tokens, button styles and `themedWindow()` live in `App/Sources/Theme/AppTheme.swift`.

### 3.6 Development signing (replaces the Electron dev-host machinery)

- Debug builds are signed with a stable Apple Development identity and a fixed bundle ID `com.myscreencam.app.dev`, so TCC grants (Screen Recording, Input Monitoring, Camera, Mic) **persist across rebuilds**.
- **Bundle IDs (new):** release `com.myscreencam.app`, debug `com.myscreencam.app.dev`.
- Dev builds use `~/Movies/My Screen Cam Dev/<worktree-id>/` through a build-setting or environment override. Release builds use `~/Movies/My Screen Cam/`.
- Hardened Runtime. Not sandboxed at first (Developer ID distribution); the sandbox can be evaluated later, since it would need the Movies-folder entitlement.

---

## 4. Recording package format (new, version 1)

This is a fresh format. The old app's recordings are not read.

```
Recording_YYYYMMDD_HHMMSS_xxxxxxxx/
├── meta.json          # host-clock stream offsets, pixel size + scale, capture rect, device uniqueIDs, codec info, pause ranges
├── edit.json          # all effect times in SOURCE seconds
├── events.jsonl       # move/drag/down/up/scroll, cursor image id, normalised coords; buffered writes
├── cursors/           # captured cursor images + hotspots + classified kind (index.json)
├── screen.mov         # HEVC (VFR, fragmented)
├── webcam.mov         # HEVC
├── sysaudio.m4a
├── mic.m4a
└── cache/             # thumbnail.heic, waveform-*.bin (safe to delete)
```

- `EditConfig` is a versioned `Codable` struct with defaulted fields, so future fields can be added without migrations breaking. The useful logic tests from the old TS code (segments, auto-zoom seeding, presets) are ported to Swift Testing as behaviour specs.

---

## 5. Module / repo layout

```
myscreenart-native/
├── App/                         # XcodeGen app target
│   ├── MyScreenCamApp.swift     # @main, scenes, MenuBarExtra, AppDelegate adaptor
│   ├── Library/ Recorder/ Editor/ Export/ Settings/
│   ├── Editor/Timeline/         # AppKit NSView + CALayers, hosted via NSViewRepresentable
│   ├── HUD/  Hotkeys/  Intents/  Updates/
│   ├── Resources/ (cursors/*.svg, Assets.xcassets)
│   ├── Info.plist  MyScreenCam.entitlements
├── Packages/MyScreenCamKit/      # SwiftPM
│   ├── Sources/{CaptureKit,RecordingKit,ProjectKit,RenderKit,ExportKit}
│   └── Tests/…                   # Swift Testing; golden-frame render tests
├── project.yml                  # XcodeGen
├── mise.toml                    # build/test/run/release tasks
├── scripts/release/             # sign, notarize, DMG, appcast
└── docs/
```

---

## 6. Performance budget (targets — validated against a measured baseline)

Phase 0 measures the current Electron app on this machine (M5 Max) with Instruments, `powermetrics` and Activity Monitor. The new app must beat those numbers, and should get close to these targets:

| Scenario | Target |
|---|---|
| Idle, library open | ~0% CPU, < 80 MB RSS, no timers firing |
| Recording 4K Retina @60 + webcam 720p + 2 audio tracks | < 10–15% of one core for the whole process; 0 dropped frames; GPU/media engine does the encoding |
| Recording, static screen | Near-idle (VFR, no duplicate frames) |
| Editor playback 4K source in a 1440p window | Smooth 60 fps; main thread idle between frames; no SwiftUI re-render per frame |
| Export (see `docs/perf-baseline.md`) | Wall time ≤ legacy (which runs 5–9× realtime by using 10–14 cores); CPU time ≤ 15% of legacy; memory < 400 MB (legacy: 2.5 GB) |
| A/V sync | ≤ 1 frame across all streams, including after cuts |
| App bundle size | < 20 MB (vs Electron + FFmpeg ≈ several hundred MB) |

Instruments signposts (`OSSignposter`) are added around capture, append, composite and encode so regressions are measurable.

---

## 7. Phased delivery

Each phase ends with a usable build and tests. The pure logic in the engine packages is test-driven.

| # | Phase | Contents | Exit criteria |
|---|---|---|---|
| 0 | **Scaffold & baseline** | Repo layout, XcodeGen, mise tasks, dev signing, CI (GitHub macOS runner: build + `swift test`), baseline measurements of the old app | `mise run run` launches an empty signed app; baseline numbers recorded in `docs/perf-baseline.md` |
| 1 | **Capture & record** | Permissions, displays/windows/devices, SCStream → AVAssetWriter, webcam, mic + system audio, event tap, cursor-image capture + classification, package writer, Recorder UI (source picker, live previews, mic meter, countdown), HUD, MenuBarExtra, hotkeys. **Extras:** region capture (drag-to-select overlay → `sourceRect`), pause/resume (writers skip paused spans; pause ranges in `meta.json`), `SCContentSharingPicker` as a source option | 30-min 4K60 recording with webcam and both audio tracks, including pauses; sync ≤ 1 frame; CPU within budget |
| 2 | **Library & project model** | Package reader, thumbnails, rename/delete, Codable EditConfig, UndoManager edit store, autosave | Library lists 100+ recordings instantly with thumbnails; edits survive a crash |
| 3 | **Render engine** | Segment/time mapping, composition builder, Metal/CI compositor with zoom, webcam, blur, cursor (three styles, smoothing, clicks, drag trail, hide-when-idle), audio mix + tap, golden-frame tests. **Extras:** mouse-follow zoom (camera follows the smoothed cursor with a dead-zone), background/canvas (output aspect ratio, padding, solid/gradient/image background, rounded frame corners, shadow) | Golden tests pass; the same frame renders identically in preview and export |
| 4 | **Editor UI** | Player + transport, AppKit timeline (ruler, segments, cut/delete, **trim handles**, waveforms, clicks, zoom keyframe and blur drag, webcam offset drag), panels (Zoom, Webcam, Audio + meters, Blur, Cursor with the style switcher, **Background**), click-to-set zoom target on the preview, presets, keyboard shortcuts | Full editing parity + undo/redo; no per-frame SwiftUI invalidation (checked in Instruments) |
| 5 | **Export** | Reader/writer pipeline, presets, codecs, output scale, progress/cancel, notifications. **Extra:** GIF export (ImageIO, palette-limited, fps/scale options) | Exports of every preset play in QuickTime/Safari; faster than realtime targets met |
| 6 | **Shell & distribution** | Sparkle, URL scheme, App Intents, Dock-hiding, quit guards, Developer ID signing, notarization, DMG, release workflow. **Extra:** Quick Look thumbnail extension for recording packages | Signed, notarized DMG installs and self-updates; packages show thumbnails in Finder |

The `docs/todo` Screen Studio parity backlog (186 items) stays a post-v1 backlog. Items are pulled in only once v1 ships.

---

## 8. Risks and spikes

| Risk | Mitigation |
|---|---|
| Scrubbing long-GOP HEVC through `AVPlayer` with a custom compositor may lag | ~1 s keyframe interval when recording; `seek(to:toleranceBefore:.zero…)` only when the scrub settles, a tolerant seek while dragging; spike in phase 3 |
| `NSCursor.currentSystemCursor` cost/behaviour | Phase 1 spike; fall back to the 3 bundled cursor types if it's unreliable |
| `AVAudioMix` volume is capped at 1.0 | `MTAudioProcessingTap` for gain > 0 dB (also used for meters) |
| macOS 15+ recurring screen-capture consent prompts | Evaluate `SCContentSharingPicker` as the primary source picker, since it avoids the persistent-permission nag |
| TCC resets during development | Stable dev signing identity + bundle ID (§3.6) |
| Xcode currently not selected (`xcode-select` → CLT) | mise tasks set `DEVELOPER_DIR`; or run `sudo xcode-select -s /Applications/Xcode.app` once |

---

## 9. Decisions

| # | Decision | Outcome |
|---|---|---|
| 1 | Minimum macOS | **15 Sequoia** (default; not yet confirmed by the user) |
| 2 | Bundle ID | **New**: `com.myscreencam.app` / `com.myscreencam.app.dev` (user) |
| 3 | Old recordings | **Not supported**: the old app was never released (user) |
| 4 | Recording codec | **HEVC** (default; not yet confirmed by the user). ProRes 422 Proxy can be offered later as a setting |
| 5 | v1 scope | **Full parity with bugs fixed, plus extras**: region capture, pause/resume, mouse-follow zoom, background/padding/frame, GIF export, Quick Look (user) |
| 6 | Cursor | **Real system cursor by default**, with a switch to stylised or fixed cursors (user) |
