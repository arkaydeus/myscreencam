# Automatic subtitles: plan

Status: **implemented (2026-09-27)**. Outcomes and deviations are in §10. Measurements, SDK facts and limitations
are in `docs/speech-integration.md`. Source spec: `local-stt-implementation-spec.md` (repo root). The decisions are
in §9.

## 1. What the user gets

1. **Settings → Subtitles** (a new tab). Choose a speech engine:
   - **Off** (the default). Nothing is downloaded.
   - **Parakeet Ultra (default)**. About 632 MB. Fast, has native word timing, and covers 25 European languages.
   - **Qwen (multilingual)**. About 3.75 GB: 2.47 GB for recognition plus 1.28 GB for the alignment model that
     supplies word timing. It covers 30 languages, and 11 of them get fine timing.

   Choosing an engine shows the real download size and asks for confirmation. The download then starts, with a
   progress bar, bytes done and total, current speed, time remaining, and a Cancel button. After that the row
   shows *Installed* with a **Remove** button. Other controls: **Language** (Automatic by default) and
   **Transcribe new recordings automatically** (on by default).
2. **Editor → Subtitles** is a new inspector tab (`captions.bubble`). It appears when an engine is ready or when
   the recording already has subtitles.
   - **Style** (at the top): font family, size, text colour, **bold**, *italic*, outline width and colour, and a
     background box toggle with its colour and **opacity**. Also the **default position**: bottom, middle or top,
     plus a margin slider.
   - **Status**: *Transcribing… 42%* with Cancel. If there's no transcript, a *Generate Subtitles* button.
   - **Cue list**: a scrolling, timestamped list. The cue under the playhead is highlighted. Clicking a cue
     pauses, seeks to it and opens it for editing: its text, plus start and end times (see Q3), Delete and
     *Reset position*.
3. **Preview**: while paused, you can drag the subtitle showing at the playhead. That gives that cue its own
   position. Cues you haven't moved follow the default position. There's also a *Reset all positions* button.
4. **After recording**: if an engine is ready and auto-transcribe is on, transcription starts as soon as the
   recording is saved. The editor opens right away and fills in the subtitles when the job finishes.
5. **Export**: subtitles are burned into MOV, MP4 and GIF exports by the same renderer as the preview, so
   what you see is what you export. The export sheet also has an **Also save .srt** checkbox. The .srt uses
   edited-timeline times and splits any cue that crosses a cut.
6. **Timeline**: a **Subtitles** row shows each cue as a block. You can drag a block to move it in time and drag
   its edges to trim it, the same way as blur masks.
7. **Transcript search** (at the top of the cue list, ⌘F): matching cues are highlighted, and ↩ or ⇧↩ jumps to
   the next or previous match.
8. **Cutting from the transcript**: the cue editor shows the cue's words as chips. Click and shift-click to
   select a run of words, then choose **Cut Words**. That becomes a normal segment cut with undo and redo. It's
   only enabled for words with fine timing; coarse or estimated timing shows why it's disabled. **Cut Cue**
   removes the whole cue's time range.
9. **Regenerate** (for example, with the other engine) makes a *candidate* revision and doesn't touch your
   subtitles. A banner offers **Use New Transcript** or **Discard**. When you use it, your corrections are kept
   wherever the recognised words under them haven't changed. Where they have, you see a conflict list and choose
   *Keep mine* or *Use new* for each one. For Qwen languages with fine timing, a corrected cue can be
   **re-timed**: the aligner runs again on just that cue's audio with some context around it.

## 2. How it fits the existing architecture

| Piece | Where | Notes |
|---|---|---|
| Transcript model (`TranscriptRevision`, segments, units, `ModelIdentity`) | `ProjectKit/Transcript.swift` | Follows the spec's §4 contract, adapted to Swift. Times are **session seconds** (the app's existing source-time convention) plus integer 16 kHz sample indices for prepared audio. Stored immutably at `transcripts/<revisionID>.json` in the `.msarec`. |
| Subtitle edit state | `EditConfig.subtitles` (`SubtitleSettings`) | `enabled`, `style`, `defaultPlacement`, `cues: [SubtitleCue]`, `sourceRevisionID`, `audioSource`. A cue has `id`, `start`, `end` (source seconds), `text` and `position: NormPoint?` (its own position when moved). Living in the edit gives undo/redo, autosave and presets for free. Decoded with `decodeIfPresent`, so older `edit.json` files still load. |
| Cue building (words → cues) | `ProjectKit/CueBuilder.swift` | Pure and tested. Rules: at most 2 lines of about 42 characters, at most 6 s per cue, and splits at sentence ends and at pauses of 0.6 s or more. It never invents timing: units without timing are joined to a neighbour's range. |
| Subtitle layout and rendering | `RenderKit/Compositor/SubtitleRenderer.swift`, `Math/SubtitleLayout.swift` | Step 7 in `FrameRenderer.compose`, after the webcam, in **canvas** space, so subtitles don't zoom with the content. Core Text lays out and rasterises **one image per cue and style**, cached in `RenderSnapshot`. Each frame then only does a GPU composite. Sizes are fractions of canvas height, so every export resolution matches the preview. `SubtitleLayout` is the pure geometry the preview uses for hit-testing. |
| Preview drag | `Editor/Preview/PreviewView.swift` | Adds a subtitle hover outline and drag to `PreviewNSView`, using the same `Drag` pattern as the webcam and blur masks. It's paused-only, like blur masks, and each drag is one undo step. |
| Subtitles panel | `Editor/Panels/SubtitlesPanel.swift` + `InspectorTab.subtitles` | Style is a collapsible section. The cue list is a `ScrollView` + `LazyVStack` that fills the rest of the panel, so it scrolls on its own. |
| Settings UI and state | `Shell/SettingsView.swift` (new `Tab("Subtitles")`), `Transcription/SpeechSettings.swift` | Uses `UserDefaults`, like `ShellSettings`. |
| Model catalogue, download and verify | `SpeechCore` (new module in `MyScreenArtKit`, no third-party dependencies) | The catalogue JSON pins the Hugging Face **revision SHA, every file path, byte size and SHA-256**, taken from the HF tree API when this is built. `URLSession` downloads with a delegate for progress. Speed is an average over about 3 s; time left is remaining bytes divided by speed. It checks free disk space first, resumes after interruptions using `resumeData`, verifies SHA-256 with CryptoKit, and rejects path traversal. Files download to `Models/.staging/…` and are renamed into place in one step once verified. The model states are `notInstalled`, `downloading`, `verifying`, `installed`, `preparing`, `ready`, `failed` and `removing` (spec §7). |
| Audio preparation | `SpeechCore/AudioPreparation.swift` | `AVAssetReader` reads the chosen track and converts it to **16 kHz mono Float32** with `AVAudioConverter`. The output is a disk-backed temporary file under `cache/`. The track's `startOffset` in `meta.json` is added once to map back to session time. The source is the microphone if it was recorded, otherwise system audio. You can pick it in the panel. It never runs on a mix with background audio unless you choose that. |
| Job queue | `App/Sources/Transcription/TranscriptionCenter.swift` (new app area, like `ExportCenter`) | One queue; one job at a time. It starts from the existing `.recordingFinished` notification, and from *Generate* in the editor. Stages: preparing audio → loading model → transcribing → (Qwen) adding word timing → building subtitles → saving. Progress comes from real coverage (seconds recognised). Cancel works at every stage, and a cancelled job never saves. It holds off new work while an export runs (`ExportCenter.isExporting`). The app delegate's quit path cancels it. |
| Inference | **`MyScreenArtSpeech.xpc`** (see Q1) + new SwiftPM package `Packages/SpeechEngines` | `ParakeetAdapter` uses FluidAudio `.ultra`, loaded **only from the local model directory**. `QwenAdapter` uses MLX Audio Swift `Qwen3ASRModel.fromModelDirectory` with windows of 20 to 30 s. `QwenAlignmentAdapter` uses `Qwen3ForcedAligner`. Only one model is loaded at a time. Qwen runs all recognition first, unloads, then loads the aligner. The worker returns plain `Codable` results and never writes into the project. |
| Saving results | `TranscriptionCenter` → `EditorSessions` | A new documented cross-area API: `EditorSessions.applySubtitles(_:to:)`. If the editor is open, the result goes in as one undoable edit named "Generate Subtitles". If not, it's written to `edit.json` with an atomic write. If you already have edited cues, it asks before replacing them (see Q4). |

Layering stays one-way. `SpeechCore` depends on `MyScreenArtCore` and `ProjectKit`. `SpeechEngines`, which holds
the third-party packages, is linked **only** by the XPC target. The app, the Quick Look extension and
`swift test` of `MyScreenArtKit` never compile MLX.

## 3. Dependencies (an exception to "Sparkle only")

The spec requires these, and there's no Apple-framework equivalent for these models:
- `FluidAudio`: pinned to **v0.17.3** as the spec says. v0.17.4 shipped on 2026-09-25; we'd only move if the spike needs a fix from it.
- `mlx-audio-swift`: pinned to one reviewed commit (current `main` is `01dec7c9bd`, 2026-09-18). We use only the `MLXAudioSTT` and `MLXAudioCore` products. It brings in `mlx-swift`, `mlx-swift-lm`, `swift-transformers` and `swift-huggingface`. `Package.resolved` is committed.
- `mlx-audio-swift` needs **Swift tools 6.2**. The toolchain here is Swift 6.4 (Xcode 27), so that's fine. The minimum macOS stays at 15.

## 4. Offline and privacy guarantees
- Nothing downloads until you pick an engine in Settings and confirm.
- The worker only receives model directories that `SpeechCore` has verified. We never call repository-name
  loaders such as `downloadAndLoad` or `fromPretrained`. Tests check that transcription works with networking
  blocked.
- Logs record stages, durations and model revisions. They never contain transcript text or full paths.
- Model licences (CC-BY-4.0 for Parakeet Ultra, Apache-2.0 for Qwen) are listed in the Settings tab and the About acknowledgements.

## 5. Phases
0. **Spike.** Pin the packages. Set up the XPC target in `project.yml`. Load Parakeet Ultra from a local
   directory and transcribe a sample. Load Qwen ASR and the aligner from local directories and align a sample.
   Check timing units and cancellation, and that MLX's Metal library resolves in a **signed Release build**. I'll
   record the SDK facts in `docs/speech-integration.md`. If anything blocks here, I'll stop and report it.
1. **Foundation.** Transcript and subtitle models (with decode-compat tests), `CueBuilder`, `SubtitleLayout`,
   catalogue with real hashes, `ModelStore` (download, verify, promote and remove, with tests using a local
   `URLProtocol`), audio preparation (offset and resample tests), and the XPC protocol types.
2. **Settings and downloads.** The Subtitles settings tab, consent, progress, speed, time left, cancel/resume and remove.
3. **Parakeet slice.** Worker, `TranscriptionCenter`, auto-run after recording, and the editor tab (status, cue list, editing).
4. **Rendering and drag.** `SubtitleRenderer` in `FrameRenderer` (preview and export), style controls,
   default position, per-cue drag in the preview, the timeline Subtitles row, and the .srt export option.
5. **Qwen slice.** Qwen recognition, then unload, then alignment; language gating; checks for incomplete output;
   re-timing a corrected cue.
5b. **Transcript editing.** Search, word chips with Cut Words and Cut Cue, candidate revisions with merging
   corrections and resolving conflicts, checkpoints and resume, and memory-pressure and playback admission.
6. **Verification.** `mise run check`, a perf sample of playback with subtitles on
   (`docs/perf-baseline.md`), and an on-device test of both engines from a signed build with the network off.
   Results are recorded here.

## 6. Tests (Swift Testing, no model downloads)
Tests cover:
- `EditConfig` decoding of older files, and round trips.
- `CueBuilder`: pauses, punctuation, CJK text without spaces, long words, and units without timing.
- `SubtitleLayout`: wrapping, anchors, clamping inside the canvas, and cue position overrides.
- Rendering: a subtitle is present in the frame, and preview and export produce the same pixels.
- Download manager: progress, speed and time left, hash mismatch, cancel/resume, low disk, and path traversal.
- Audio preparation: stream offset, resampling to 16 kHz, and stereo downmix.
- `TranscriptionCenter` with a fake worker: cancellation at each stage, late results after cancel, and the editor-open and editor-closed save paths.

## 7. How the spec maps onto this app (full scope, per Q4)
- **Timeline mapping (spec §9)**: the app has one source and ordered kept segments, with no rates, duplicates or
  ramps. `EditTimeline` is the mapping from source time to timeline time. Cues and transcripts stay in source
  time. Cut ranges hide the parts of a cue that fall in them. The list greys out cues that are entirely cut. SRT
  export splits cues at cuts.
- **Corrections vs. raw output**: raw revisions are immutable (`transcripts/<id>.json`). Each cue records
  `generatedText` and the IDs of the units it came from, so a correction is a difference anchored to source time
  and units, not to character offsets. The merge rules are in item 9 of §1. Inserted text that was never spoken
  gets `method: manual` timing and is never labelled as aligned.
- **Checkpoints**: finished work units are saved under `cache/transcription/<recognitionKey>/`. A job
  interrupted by quit, sleep or a worker crash resumes from the last finished unit with the same model and
  options. It retries automatically at most once and never loops on a crash that repeats.
- **Resource policy**: new Qwen work isn't started while the editor is playing or an export is running. On
  memory pressure (`DispatchSource.makeMemoryPressureSource`), the job saves a checkpoint and the XPC service is
  recycled. It never switches your model without telling you.
- **Cache keys**: the spec's `preparedAudioKey`, `recognitionKey`, `alignmentKey` and `captionKey`. They hash
  `meta.id`, the stream file's size and modification date, and the recipe, so a same-path file that's been
  replaced isn't reused.
- **Smoke and benchmark**: a `speech-tool` executable in `Packages/SpeechEngines`. It transcribes a `.msarec` or
  audio file with either engine and reports cold/warm load time, real-time factor, peak memory and cancellation
  latency. It also compares the 8-bit and BF16 aligners on timing fixtures, measuring the median and p95 boundary
  error. Results go in `docs/speech-integration.md`.
- **Not built** (and not required by the spec): karaoke word highlighting, live transcription while recording,
  translation and diarisation. The data model keeps them possible.

## 8. Defaults I'll use unless you say otherwise
- Audio source: microphone, falling back to system audio. It can be changed per recording in the panel.
- Language: Automatic. Qwen only uses fine timing for its 11 aligner languages. For other languages it says so and doesn't fake timing.
- Both engines can be installed at the same time. The picker chooses which one runs, and each has its own Remove button.
- Default style: SF Pro Semibold at 5% of canvas height, white text, a 2 px black outline, and a black background box at 55% opacity, 7% from the bottom.
- Recordings that already exist get a *Generate Subtitles* button. They're never transcribed automatically.

## 9. Decisions (settled 2026-09-27)
- **Q1 Where inference runs → XPC service.** It's started on demand and exits when idle, so all Core ML and MLX
  memory goes back to the OS. A crash in a model can't take down the editor, and a hard cancel is just ending
  the connection.
- **Q2 Subtitle export → burn-in plus optional .srt.** Subtitles are burned in whenever they're enabled, and the
  export sheet has an *Also save .srt* checkbox.
- **Q3 Timing edits → fields and a timeline row.** Start and end fields in the cue editor, plus a *Subtitles* row
  on the timeline with cue blocks you can drag and trim, like blur masks.
- **Q4 Scope → the full spec.** Search, cutting from the transcript, merging corrections, checkpoints and resume,
  resource policy, and benchmarks (§7).

## 10. Outcomes (2026-09-27)

All phases are built. Unit tests cover the engine side, and the app flow was checked end to end in the Debug app:
- Settings: consent, then download with progress, speed and time left.
- Parakeet transcription through the XPC service.
- The cue list, cue editing, and dragging in the preview.
- The timeline row.
- Regenerating with Qwen: candidate, then adopt with corrections kept.
- Cut Words.
- Burned-in export.

Deviations and additions found while building:
- **Seams.** Word ownership is by start time, with a timing-based seam merge (§"Seams" in `speech-integration.md`).
  The long-file benchmark found both duplicated and dropped words with simpler rules.
- **Resampling.** `AVAssetReader` resamples to 16 kHz. `AVAudioConverter` priming shifted audio 36 ms late and
  truncated its end, as the unit tests showed.
- **Parakeet start times** run 50–180 ms early depending on context. This is documented; no constant correction.
  The Qwen aligner measured a 27 ms median and 67 ms p95 error.
- **Aligner precision.** The 8-bit and BF16 aligners are identical at p95, so 8-bit ships.
- **Fine-timing languages.** Qwen claims fine timing for 9 languages; the Swift aligner can't tokenise Japanese or
  Korean.
- **Cut Words** also removes the words from the subtitle's text, in the same undo step, unless the user rewrote
  that text.
- **Tab visibility.** The Subtitles tab appears only once an engine is enabled or the recording already has
  subtitles.
- **Build trust.** The build tasks pass `-skipPackagePluginValidation -skipMacroValidation` for mlx-swift's plugin.
  Building needs the Metal Toolchain component.

Not yet done: the notarised release build, measurements on a 16 GB Mac, and real-speech fixtures (details in
`speech-integration.md`, Limitations).
