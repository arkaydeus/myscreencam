# Legacy app feature inventory (reference spec)

A condensed inventory of what the old Electron/Rust app (`/Users/arkaydeus/project/apps/myscreenart`) does. Use it for **behaviour, defaults and UX**, not for implementation.
- Known bugs are marked **BUG**. Do not reproduce them.
- The native package format and edit model are **new** (see `ProjectKit`). We don't read or write old files.

## 1. Recording

**Sources:**
- Display (dropdown: "name (W×H) (Primary)") or Window (dropdown: app name, title and W×H, plus a refresh button).
- Native adds **region** capture and the system `SCContentSharingPicker`.

**Options:**
- System Audio switch (default on).
- Custom Cursor switch: hides the system cursor in the capture and records pointer events. It needs Input Monitoring.
- Webcam picker (optional, "None") and Microphone picker (optional, "None").
- If a permission is missing, a "Grant … access" button replaces the picker.

**Recorder view:**
- A live webcam preview.
- A mic level meter (green → yellow → red).
- A still capture-source preview.
- A permissions card: Screen Recording, Camera, Microphone, Input Monitoring. It re-checks when the app becomes active.
- Warnings: "camera without mic", and "previously selected device disconnected".

**Countdown:** 3 s. The Start button becomes "Cancel · Recording in N".

**While recording:**
- A pulsing "Recording" label, an elapsed timer (mm:ss) and a Stop button.
- Stopping opens the editor on the new recording.

**Saved preferences:** capture mode, display ID, window ID, webcam (restored by name first, then ID), mic, system audio, custom cursor.

**Auto-stop:** if the captured window closes, the recording stops.

**Old defaults:** screen at 60 fps; webcam at 1280×720 @30; 48 kHz audio.

## 2. Input events and cursor

- Listen-only event tap: move, drag, down/up (left/right/other). Native adds scroll.
- Positions are relative to the captured content.
- Old cursor types were only arrow, pointingHand and iBeam. **BUG:** the old code polled `NSCursor.currentCursor`, which only sees the app's own cursor. Native captures real system cursor images (`NSCursor.currentSystemCursor`) and classifies them.

## 3. Editor

**Layout:**
- Header: Presets menu, Back, a project name that you click to rename (Enter commits, Esc cancels), the date, Delete (with a confirm dialog), and Export.
- Body: preview on the left, transport bar, timeline at the bottom, and a 320 pt right panel with tabs **Zoom / Webcam / Audio / Blur / Cursor**. Native adds **Background**.

**Transport:**
- Time / edited duration.
- Back 5 s, Play/Pause, Forward 5 s.
- Cut at the playhead. It refuses within 0.1 s of a segment edge, with "Too close to edge".
- Delete the selected segment; reset cuts.
- Timeline zoom from 50% to 400% in 25% steps.

**Keyboard** (ignored while a text field has focus):

| Key | Action |
|---|---|
| Space | Play/pause |
| ← / → | Step one frame (1/60 s); with Shift, 1 s |
| Home / End | Jump to start / end |
| C | Cut |
| Delete / Backspace | Delete the selected segment |
| Esc | Deselect |

Native adds ⌘Z / ⇧⌘Z undo/redo and ⌘E export (both were missing or broken in the old app).

**Timeline rows:**
- Ruler: tick spacing adapts to duration and zoom.
- Screen: kept segments as blocks you click to select.
- Webcam: drag sideways to set the sync offset (±5 s); double-click resets it.
- System audio and mic: waveforms.
- Blur: bars. Drag the body to move; drag an edge to resize (minimum 0.5 s).
- Clicks: a dot per mouse-down.
- Zoom keyframes: blocks you drag to move (3 px threshold).

**Timeline interaction:**
- Drag the red playhead; the view auto-scrolls near the edges.
- Mouse wheel: vertical zooms (0.5–4×), horizontal scrolls.
- The view keeps the playhead in sight.

**Trim handles:** the old app had none (**BUG**). Native trims by dragging the outer edges of the first and last segments.

**Zoom panel:**
- Enable switch.
- "Create zooms from clicks" (applies to new recordings).
- Defaults: scale 1.1–4, ease-in 0.05–1 s, hold 0.1–2 s, ease-out 0.05–1 s.
- Keyframe list, and "Add" at the playhead.
- For the selected keyframe: enabled, instant, scale, target X/Y, mode, duplicate (placed at the end + 0.2 s), delete.
- Native adds click-to-set-target on the preview, and **follow-mouse** mode.

**Webcam panel:**
- Show; Mirror.
- Position presets: bottom-right, bottom-left, top-right, top-left, centre.
- X/Y sliders.
- Size presets S/M/L (0.15 / 0.2 / 0.3 of width), W/H sliders 0.05–0.5.
- Shape: Square / Rounded / Circle, with a radius slider 0–0.5.
- Aspect: Wide / Square.
- Sync offset ±5 s with Reset.
- The webcam is also draggable on the preview.

**Audio panel:**
- Per track (system, mic): Enabled, Mute, Gain −20…+10 dB in 0.5 dB steps.
- Level meter: RMS×2, peak held for 1.5 s then decays, red at ≥0.99.

**Blur panel:**
- "Add Mask" at the playhead: 5 s long, region {x .3, y .3, w .2, h .15}, intensity 20.
- List of masks; intensity 1–50; X/Y/W/H sliders.
- Masks are draggable and resizable (8 handles) on the preview.

**Cursor panel:**
- Enable.
- Style: native **System / Stylised / Fixed(type)**.
- Size S/M/L.
- Smoothing: none / rapid / medium / slow.
- Hide when idle.
- Click highlight: colour (default `#3b82f6`), radius 10–100 (default 30), duration 0.1–1 s (default 0.3).
- Drag trail: enabled, length 2–15 (default 5), opacity (default 0.5).

**Presets:**
- Named presets that save the webcam, audio, cursor, zoom-default and (native) background settings. They don't save keyframes.
- Saving with an existing name replaces it (case-insensitive).
- Applying a preset keeps the project's keyframes.

**Autosave:**
- Debounced 500 ms, latest state wins.
- Also flushed on window close, project switch, rename, and app quit.

## 4. Render semantics (native must be identical in preview and export)

**Effect order:**
1. Source screen.
2. Blur masks (they zoom with the content).
3. Zoom transform.
4. Cursor. It is drawn in source space, so it moves and scales **with** the zoom. **BUG:** the old app drew it after the zoom.
5. Background/padding frame (native).
6. Webcam overlay on top. It is not zoomed.

**Zoom:**
- Timing:
  - `inEnd = t + in`, `holdEnd = inEnd + hold`, `end = holdEnd + out`.
  - Instant keyframes have in = out = 0.
- Scale is `lerp(1, s, e(p))` with **easeInOutCubic**: `p < .5 ? 4p³ : 1 − (−2p+2)³/2`. Use it in both preview and export. **BUG:** the old export was linear.
- Pivot: scale by `z` about `(tx·W, ty·H)`. In crop form:
  - origin `x = tx·(W − W/z)`, `y = ty·(H − H/z)`;
  - size `W/z × H/z`.
  - This stays in bounds for tx, ty ∈ [0,1].
- Overlapping keyframes: the earliest one wins.
- Only keyframes that are enabled render, and only when zoom is enabled.
- **Auto-zoom from left clicks:**
  - `t = max(0, click.t − 0.12)`.
  - Skip a click if `t < previousEnd + 0.18`.
  - Scale 1.6; in 0.16 / hold 0.85 / out 0.24.
  - Target = the click position, clamped to 0–1.

**Webcam:**
- Offset = the stream's start offset relative to the screen, plus `syncOffset`.
- It must be **cut with the same segments** as the screen. **BUG:** the old app didn't.
- Layout `{x, y, w, h}` is a fraction of the output (content) frame; x and y are the top-left corner.
- Aspect:
  - Wide = source aspect, fitted to `w`.
  - Square = a centre crop.
- Corner radius is a fraction (0–0.5) of the shorter side; 0.5 gives a circle or pill.
- Anti-aliased edges, with a soft shadow `0 4 12 rgba(0,0,0,.3)`.

**Blur:**
- A rectangle in normalised source coordinates, active on `[start, end]` in source time.
- Gaussian, with the radius given in source pixels (intensity 1–50).

**Cursor:**
- Linear interpolation between events, optionally spring-smoothed.
- Size multiplier S/M/L = 0.75 / 1.0 / 1.5 × the native cursor size. The old app used 24/36/48 px.
- Drawn at the hotspot.
- **Click highlight:** a filled circle with `radius = R·p`, `opacity = 0.5·(1−p)`, where `p = (t−t0)/duration`.
- **Click pulse:** the cursor scales 1 → 1.3 → 1 over 0.3 s, **about its hotspot**. **BUG:** the old app scaled about the top-left corner.
- Before the first event, the cursor is hidden.

**Audio:**
- Gain = `10^(dB/20)`.
- Mixed by summing with a soft limiter. **BUG:** the old `amix` halved the volume.
- Tracks that are disabled or muted are removed.

**Time bases:**
- **All effect times are in SOURCE (session) seconds.**
- Segments list the kept source ranges.
- Edited time maps to source time by walking the segments. **BUG:** the old app evaluated source-time effects against edited time.

## 5. Export dialog

**Presets:**
- Web: H.264 1080p30.
- Smooth: 60 fps.
- Compact: 24 fps, lower bitrate.
- Master: ProRes 422.
- GIF (native).

**Options:**
- Quality: low / medium / high / max.
- Frame rate: 24 / 30 / 60.
- Resolution scale: 100 / 75 / 50%.
- Codec and fps are remembered.
- Output via a save panel (default `<project name>.mp4`).

**Progress:** stage text, percent, a bar and Cancel. The dialog can't close while exporting.

**Done:** check mark, the output path, "Show in Finder" and Done. Native also posts a notification.

**Error:** shown inline.

**Correctness:**
- Odd output dimensions must work. **BUG:** the old app failed on 2056×1329.
- Progress must never freeze.

## 6. Projects / library

- Grid of 1–3 columns: thumbnail, a duration badge, "Open" on hover, name, date, and icons for screen / webcam / system audio / mic.
- Header: "N recordings", Refresh, New Recording. There is an empty state.
- **BUG:** old thumbnails loaded the whole `screen.mov`. Native uses a cached still image.
- Native adds rename and delete from the card's context menu.

## 7. App shell

- **Window:** 1280×800 by default, minimum 900×600, hidden title bar. The window position is restored.
- **Tray (menu bar):**
  - Idle: Record Display / Record Window.
  - Recording: Finish Recording.
  - Always: Show Projects, Quit.
  - While recording, the tooltip reads "MyScreenArt — Recording".
- **Dock menu:** the same items.
- **Global shortcut:** ⌥⌘↩ opens a new recording.
- **App menu:**
  - Check for Updates….
  - "Hide Dock Icon When Idle" checkbox.
  - Reset Window Position.
- **File menu:** Projects ⌘1, New Recording ⌥⌘↩, Finish Recording ⇧⌘R (only while recording), Open Recording… ⌘O, Export… ⌘E.
- **Dock icon:** if the preference is on, it hides when the window closes and nothing is recording, and reappears when a recording starts.
- **Last window closed:** the app does **not** quit.
- **URL scheme** `myscreenart://` (dev: `myscreenart-dev://`):

  | Command | Opens |
  |---|---|
  | `record`, `new-recording` | New Recording |
  | `display`, `record-display` | Display tab |
  | `window`, `record-window` | Window tab |
  | `projects`, `show-projects` | Projects |

  The action comes from the URL's host or path.
- **Quit guards:**
  - Recording → "Stop Recording and Quit" / "Keep Recording".
  - Exporting → "Cancel Export and Quit" / "Quit When Export Finishes" / "Keep App Open".
- **Updates:**
  - Checked 15 s after launch, then every 6 h.
  - Installing is refused while recording or exporting, or while an edit save is pending.
  - Native uses Sparkle 2.
- **Theme:** Light / Dark / System. Native follows the system and offers an override.
