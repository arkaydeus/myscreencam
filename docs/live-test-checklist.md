# Live test checklist (needs real macOS permissions)

Unit and integration tests cover everything that doesn't need TCC permissions. This checklist covers what only a real run can prove.

**Setup:**
1. Build and launch: `mise run build:perf && scripts/dev/run.sh`, or `mise run run` for Debug.
2. Grant **MyScreenArt Dev** Screen & System Audio Recording, Camera, Microphone and Input Monitoring, using the Recorder's Permissions card.
3. Relaunch after granting Screen Recording and Input Monitoring.

## Recorder
- [ ] Permission statuses update when returning to the app.
- [ ] Display tab: the preview image appears, and Refresh works.
- [ ] Window tab: the list loads, thumbnails fill in lazily, and Refresh works.
- [ ] Region: the overlay selects the correct area on Retina and secondary displays (top-left origin).
- [ ] System picker (macOS 15.2+) maps back to a display or window.
- [ ] Camera preview is live and stops when the window is closed or minimised (the camera light goes off).
- [ ] Mic meter moves (green → yellow → red) and stops when the window closes.
- [ ] Warnings appear for camera-without-mic and for a disconnected device.
- [ ] Countdown shows on the correct display, and Cancel works during it.
- [ ] The recorder window closes when recording starts, the HUD appears, and the HUD is **not** in the recording.
- [ ] HUD: drag, position remembered, Pause/Resume, Stop, Discard (with confirm → package moves to the Trash).
- [ ] Menu bar: red dot and elapsed time, orange when paused, Pause/Finish items work; ⇧⌘R / ⌥⇧⌘P / ⌥⌘↩ work.
- [ ] Finishing opens the editor, and the Library shows the new recording.
- [ ] Closing the recorded window auto-stops the recording and opens the editor.
- [ ] The webcam carries straight from the preview into the recording without reopening.
- [ ] Quitting while recording triggers the guard, then stops and saves.

## Recording output
- [ ] `screen.mov` is HEVC at native Retina pixel size, VFR (a static screen gives few frames), and fragmented (playable after a force-quit).
- [ ] A/V sync ≤ 1 frame between screen, webcam, system audio and mic (clap test).
- [ ] With pauses, the files are continuous and `meta.pauses` is recorded.
- [ ] Custom cursor: the system cursor is hidden in `screen.mov`; `cursors/` contains the real cursor images with the right kinds; the editor draws them (System / Stylised / Fixed).

## Perf (compare with `docs/perf-baseline.md`)
Run `scripts/perf/sample.py --match '<app path>/Contents/MacOS' --duration 60` for each scenario:
- [ ] Recorder window with camera preview and mic meter: < 5% CPU, < 150 MB.
- [ ] Recording a busy screen (`scripts/perf/motion-window.swift`): < 25%, < 300 MB.
- [ ] Recording a static screen: < 5%.
- [ ] Editor playback: < 15%, < 400 MB.

## Editor / export (with a real recording)
- [ ] Keyboard shortcuts with the app frontmost (Space, arrows, C, Delete, Esc), plus ⌘Z / ⇧⌘Z undo.
- [ ] Rename, delete, presets, Export sheet progress + Cancel on a long recording, notification when finished.
