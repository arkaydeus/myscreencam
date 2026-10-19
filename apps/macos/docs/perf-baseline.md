# Performance baseline

The numbers the native app has to beat. Machine: **Apple M5 Max, macOS 26.6.2**.

Tools:
- `scripts/perf/sample.py` samples a process tree: the root process plus every descendant, re-scanned on each tick.
  - CPU comes from cumulative CPU-time deltas (100% = one core).
  - Memory is summed `phys_footprint`, which is what Activity Monitor shows as "Memory".
- `scripts/perf/legacy-export-baseline.mjs` drives the old Rust daemon's `export_start` over its WebSocket, on a temporary copy of a recording, while the sampler runs.

Old app build: `/Users/arkaydeus/project/apps/myscreenart` at its current checkout. `cargo build --release`; Homebrew `ffmpeg` on `PATH`.

## Legacy export (Rust daemon + FFmpeg libx264), measured 2026-09-25

| Recording | Content | Preset | Wall | CPU time | CPU avg | Memory peak | Output |
|---|---|---|---:|---:|---:|---:|---:|
| `123dc5953d43/…130609` 52.4 s | 3008×1692 @60, webcam 720p, sys + mic audio, 10 zooms | high @30 | **6.0 s** | **73.8 s** | 12.1 cores | **2.5 GB** | 16.0 MB H.264 High |
| same | same | high @60 | **10.0 s** | **133.4 s** | 13.3 cores | **2.5 GB** | 20.0 MB |
| `1ce4ce34a19e/…124457` 13.8 s | 3008×1692, webcam, audio, custom cursor, 5 zooms | high @30 | **3.2 s** | **30.2 s** | 9.7 cores | **2.7 GB** | 8.5 MB |
| `1ce4ce34a19e/…110556` 46.1 s | 2056×**1329**, cursor, 16 zooms | high @30/@60 | **fails** | – | – | – | libx264 rejects odd height (`Error while opening encoder`) |

Reading these numbers:
- The old export has **good wall-clock time only because it runs software x264 across 10–14 cores**, using about 2.5 GB of memory to do so. It runs at 5–9× realtime on this machine.
- On a laptop on battery the same job runs the fans and drains the battery. On lower-core Macs the wall time scales down with the core count.
- Captures with an odd pixel dimension (window captures and some scaled displays) can't be exported at all.

### Native export targets (phase 5)

| Metric | Target |
|---|---|
| Wall time | ≤ legacy (≤ 6 s for the 52 s @30 case; ≤ 10 s @60) |
| CPU time | ≤ 15% of legacy (≤ 11 s for the 52 s @30 case). The media engine does the encoding and the GPU does compositing. |
| Memory peak | < 400 MB |
| Correctness | Any capture size exports. Odd dimensions are padded or cropped to the codec's alignment. |

## Legacy app: idle, recording and editor playback, measured 2026-09-25

**Method:**
- The old app was launched with its own dev supervisor (`mise run dev` in the old repo, instance `d804a0b921f0`) and driven with cua-driver.
- DevTools was closed before measuring.
- `scripts/perf/sample.py --pid <Electron main>` covered the whole tree: main process, GPU/utility/renderer helpers, the Rust daemon, and every ffmpeg child.
- The renderer ran the **Vite dev build** (development React), so the renderer-heavy rows (preview, playback) somewhat overstate a production build. The capture and encoding rows (daemon + ffmpeg) are unaffected.
- The recording source was display 2 (3008×1692, primary) at 60 fps, plus the MacBook Pro Camera (1280×720 @30), system audio, and the MacBook Pro Microphone.
- For the busy screen, `scripts/perf/motion-window.swift` scrolls page-like content at 60 fps in a 1400×900 window without taking focus.

| Scenario | Duration | CPU avg / max (100% = 1 core) | Memory avg / max | Processes |
|---|---:|---:|---:|---:|
| Idle, projects view (empty library) | 60 s | **0.2%** / 6.4% | **211 MB** / 252 MB | 5 |
| Recording view: live webcam preview + mic meter, not recording | 30 s | **33.0%** / 44.8% | **779 MB** / 910 MB | 7 |
| **Recording, busy screen** (motion window) | 60 s | **151%** / 172% | **2.13 GB** / 2.40 GB | 12 (5 × ffmpeg) |
| **Recording, mostly static screen** | 60 s | **144%** / 167% | **2.10 GB** / 2.34 GB | 12 |
| Editor open, paused | 20 s | 0.2% / 1.8% | 387 MB | 7 |
| **Editor playback** (70 s recording) | 55 s | **50.6%** / 61.3% | **767 MB** / 893 MB | 7 |

What this shows:
- **A static screen costs almost as much as a busy one** (144% vs 151%). The old pipeline re-sends duplicate BGRA frames to software x264 at a constant 60 fps, whatever the content. Variable-frame-rate capture should make the native static case close to idle.
- **Recording holds about 2.1 GB of memory**, spread across 5 ffmpeg processes (the screen x264, webcam capture, webcam x264, and two AAC encoders) plus Electron.
- The screen file runs at about 15 Mbit/s: 141 MB for the 73.6 s busy recording, H.264 High, CRF 18.
- **Just showing the recording screen costs a third of a core and 780 MB**, from `getUserMedia` preview and per-frame React meter updates.
- **Playback costs half a core** for four hand-synchronised `<video>`/`<audio>` elements plus 60 Hz React re-renders.

Other things observed while measuring:
- The busy recording (`Recording_20260925_002446_35f69cf2`) showed a **black preview and never advanced the playhead** in the old editor, although all four files probe fine (73.6 s, 4416 frames). The static recording played normally. The cause wasn't investigated.
- Two recordings made during these runs remain in `~/Movies/My Screen Cam Dev/d804a0b921f0/`. They contain real screen, webcam and mic content.

### Native recording and editor targets (phases 1 and 4)

| Scenario | Legacy | Native target |
|---|---:|---:|
| Idle | 0.2%, 211 MB | ~0%, < 80 MB |
| Recorder view with camera preview + mic meter | 33%, 779 MB | < 5%, < 150 MB |
| Recording, busy screen | 151%, 2.13 GB | < 25%, < 300 MB |
| Recording, static screen | 144%, 2.10 GB | < 5%, < 300 MB |
| Editor playback | 51%, 767 MB | < 15%, < 400 MB |

## Native app

### Export (RenderKit + ExportKit), measured 2026-09-25

**Method:** `msc-tool import-legacy` wraps the same legacy recording (`123dc5953d43/…130609`: 52.4 s, 3008×1692 @60, webcam, system + mic audio) as a `.mscam`. Auto-zoom seeding produced the same **10 zooms**, and the webcam overlay is on. Then `msc-tool export`, sampled with `sample.py`. Hardware VideoToolbox encoders; Core Image compositor on the GPU.

| Export | Wall | CPU time (process) | Memory peak | vs legacy |
|---|---:|---:|---:|---|
| HEVC @30, full size | **4.8 s** | **6.3 s** | **370 MB** | legacy H.264 @30: 6.0 s / 73.8 CPU-s / 2.5 GB → **1.25× faster, 8.5% of the CPU, 15% of the memory** |
| HEVC @60, full size | **9.9 s** | **8.9 s** | **400 MB** | legacy @60: 10.0 s / 133 CPU-s / 2.5 GB → same speed, 6.7% of the CPU |
| H.264 @30, full size | 8.0 s | 4.7 s | 383 MB | H.264 is limited by the hardware encoder at ~196 fps for 3008×1692 |
| H.264 @30, 50% | 5.5 s | 8.2 s | 866 MB ⚠︎ | memory above the 400 MB target; to investigate |
| GIF @15 fps, 50% | 7.6 s | 12.7 s | 633 MB | ImageIO |
| ProRes 422, full size | 4.9 s | 5.6 s | – | 1.39 GB file |

Findings:
- **Decode:** the source decodes at ~950 fps (3.3 s), so it isn't the bottleneck.
- **Encode:**
  - A single H.264/HEVC encode session tops out at ~200 fps at this size.
  - Two sessions in parallel only reach ~225 fps combined, so chunked parallel encoding isn't worth it.
  - `PrioritizeEncodingSpeedOverQuality`, now on except at "max" quality, makes HEVC 1.7× faster.
- **Composition:** pipelining GPU completion in the compositor made no measurable difference, because the encoder is the limit.
- **Caveat:** the H.264 legacy comparison is from a software encoder (x264, CRF 18). The native H.264/HEVC files are larger at "high" quality (38–48 MB vs 16 MB), so the bitrate model could be tuned down.

### App

| Scenario | Date | CPU avg | Memory | Notes |
|---|---|---|---|---|
| Idle, empty library window (phase 0 shell) | 2026-09-25 | 0.0% | 42 MB footprint | SwiftUI shell only, so it will grow |

## After the perf pass (2026-09-25): current numbers

**Changes:**
- Video is scaled with affine transforms instead of Lanczos. Lanczos needed full-resolution half-float intermediates every frame, and that caused the IOSurface blow-up.
- Static layers (background, masks, shadows, cursor sprites) are rasterised once and cached.
- Compositor frames in flight are capped at 3.
- Audio taps for metering are installed only while the Audio panel is visible.
- The time label is an AppKit label, so SwiftUI doesn't re-render during playback.
- `PrioritizeEncodingSpeedOverQuality` is on for exports below "max" quality.
- **Text is still crisp at 50%:** checked visually on a real 4112×2658 recording.

### Export: legacy clip (52 s, 3008×1692 @60, webcam, 2 audio tracks, 10 zooms)

| Export | Wall | CPU time | Memory peak | Legacy (FFmpeg) |
|---|---:|---:|---:|---|
| **HEVC @30** | **4.7 s** | **2.4 s** | **332 MB** | 6.0 s / 73.8 s / 2.5 GB → 1.3× faster, **3% of the CPU**, 13% of the memory |
| **HEVC @60** | **9.1 s** | **4.2 s** | **337 MB** | 10.0 s / 133 s / 2.5 GB → 1.1× faster, **3% of the CPU** |
| H.264 @30 | 8.1 s | 2.6 s | 324 MB | hardware H.264 encoder limit ~196 fps at this size |
| H.264 @30, 50% | 3.4 s | 2.7 s | 205 MB | (was 866 MB before the pass) |
| GIF 50% | 5.9 s | 8.0 s | 232 MB | (was 633 MB) |

### Export: real 227 s recording (4112×2658 HEVC VFR, webcam, 2 audio tracks, 16 zooms, cursor overlay)

| Export | Wall | CPU time | Memory peak |
|---|---:|---:|---:|
| HEVC @30, full | 36.8 s (6.2× realtime) | 13.9 s | 537 MB (11 MP frames; 16 MB per buffer) |
| H.264 @30, 50% | 23.6 s | 13.8 s | **236 MB** (was 1.8 GB) |

### Editor playback

| Measurement | CPU (1 core = 100%) | Memory | Legacy |
|---|---:|---:|---|
| Headless (`msc-tool play`, 1938×1090 preview), legacy clip | 16.3% | 240 MB | – |
| Headless, real 4112×2658 recording | 19.9% | 275 MB | – |
| **In the app** (optimised Dev build, legacy clip, 4 editor windows open) | **20.6%** | **358 MB** avg / 538 MB peak | 50.6% / 767 MB |
| In the app, idle with 4 editors open (paused) | 0.1% | 150 MB | 0.2% / 387 MB |

**Against the targets:**
- Memory meets the < 400 MB target.
- CPU is 2.5× below legacy but still above the 15% goal. The remainder is AVFoundation decode of a 60 fps Retina source, Core Image composition at display rate, and display.
- Ideas not yet taken:
  - render the preview at the source's frame rate when nothing animates;
  - a lower-resolution decode (`preferredMaximumResolution`) for small preview windows.

## Live recording (real capture, permissions granted), measured 2026-09-25

**Setup:** optimised Dev build (`mise run build:perf`). Recorder with the Built-in Retina Display (4112×2658 px, primary) @60 fps, MacBook Pro Camera (1280×720 @30), MacBook Pro Microphone, system audio and custom cursor. Two editor windows were also open, and they count towards memory.

| Scenario | CPU avg / max (1 core = 100%) | Memory avg / max | Legacy |
|---|---:|---:|---|
| Recorder window: live camera preview + mic meter | **5.3%** / 7.4% | 262 MB | 33% / 779 MB |
| **Recording, busy screen** (motion window + normal use), 60 s sample | **17.8%** / 26.3% | **296 MB** / 473 MB | 151% / 2.13 GB (and legacy captured at a smaller 3008×1692) |
| Recording, static screen | not measured | – | 144% / 2.10 GB |

The static-screen run was cut short: the recording was finished from the menu bar after 21 s while the machine was in use.

Notes:
- **Where the work runs:** encoding is in-process on the media engine. The VideoToolbox XPC encoder services stayed at 0%. `replayd` (the ScreenCaptureKit server) adds ~4% of a core; the legacy app paid that too.
- **Output of a 227 s real recording:** `screen.mov` is HEVC at 4112×2658, **VFR** (12,385 frames ≈ 54.6 fps average), 352 MB (~12.4 Mbit/s).
  - `webcam.mov` is HEVC 1280×720; both AAC tracks are present.
  - Stream start offsets are all < 0.11 s.
  - 2,275 pointer events.
  - 7 cursor kinds captured (arrow, iBeam, pointingHand, openHand, closedHand, resizeLeftRight, other).
- **Export of that recording:**

  | Export | Wall | CPU time | Memory peak |
  |---|---:|---:|---:|
  | HEVC @30, full size | 36.6 s (6.2× realtime) | 19.8 s | 563 MB |
  | H.264 @30, 50% | 31.7 s | 36.6 s | **1.8 GB** ⚠︎ being fixed |

- **Visual check of exported frames:** the zoom, webcam overlay (rounded corners, shadow) and recorded-cursor overlay are all correct, and the recording HUD is not captured.
- **Cursor de-duplication is correct:** two `resizeUpDown` entries in one recording turned out to be different system cursors (bidirectional vs "resize down only" with a greyed-out up arrow). Both classify to the same kind, which is what the stylised style needs.

## Webcam background blur and removal, measured 2026-10-18

**Setup:** `msc-tool` release build, M5 Max. A real 9.4 s recording: screen 6016×3384 HEVC @60, webcam 1280×720 @24, overlay width 35%. The effect runs Vision's "balanced" person segmentation once per webcam frame (`PersonMaskCache`); the composition re-uses the mask for the 2–3 output frames that show the same camera frame.

| Webcam background | Editor playback (`msc-tool play`, 9 s) | Export H.264 4096×2304 @30 (wall / CPU) |
|---|---:|---:|
| None | 58.8 fps, **14%** of a core | 2.73 s / 0.82 s |
| Blur | 59.1 fps, **31%** | 3.36 s / 2.42 s |
| Remove, cut-out | 59.0 fps, **30%** | 3.08 s / 2.26 s |

Notes:
- Without the cache (segmenting every output frame) playback cost 44–49% of a core.
- Segmentation alone, per 1280×720 frame including the blend: fast ≈ 3 ms (blocky mask), **balanced ≈ 8 ms**, accurate ≈ 27 ms.
- Most of the added cost is CPU time around Vision's model, so slower Macs will feel it more than this M5 Max does.
