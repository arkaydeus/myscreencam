# Speech integration notes

These notes are the phase 0–6 record for automatic subtitles (`docs/subtitles-plan.md`). They cover the SDK
facts we verified in the pinned sources, how packaging works, the measured results, and known limitations.
Measurements were taken on 2026-09-27.

## Pins

| Component | Pin | Notes |
|---|---|---|
| FluidAudio | `0.17.3` (exact), `traits: []` | `traits: []` turns off the NeMo text-normalisation binary, so we keep the recogniser's raw text. v0.17.4 exists, but we haven't needed it. |
| mlx-audio-swift | `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` | We use only `MLXAudioSTT` and `MLXAudioCore`. |
| mlx-swift / mlx-swift-lm / swift-transformers / swift-huggingface | 0.31.6 / 3.31.4 / 1.3.4 / 0.11.0 (exact) | Transitive, but pinned exactly in `Packages/SpeechEngines/Package.swift`, because the app's Xcode build resolves the graph itself and its resolution isn't committed. `Package.resolved` is committed. |
| Parakeet Ultra (Core ML) | `FluidInference/parakeet-ultra-coreml@95eaa59a…` | 21 files, 632 MB, CC-BY-4.0 |
| Qwen3-ASR 1.7B 8-bit | `mlx-community/Qwen3-ASR-1.7B-8bit@a8379a2e…` | 10 files, 2.47 GB, Apache-2.0 |
| Qwen3-ForcedAligner 0.6B 8-bit | `mlx-community/Qwen3-ForcedAligner-0.6B-8bit@0e1a68e9…` | 10 files, 1.28 GB, Apache-2.0 |

The model inventory, sizes and SHA-256 hashes live in `Packages/MyScreenArtKit/Sources/SpeechCore/Resources/catalogue.json`,
which `scripts/speech/make-catalogue.py` generates from the Hugging Face tree API at the pinned revisions. LFS
files carry their SHA-256 in that API. Small files are downloaded and hashed. To move a pin, bump the revision in
the script, regenerate the catalogue, and review the new revision's licence files. `InferenceEngine.implementation`
records the SDK versions in every transcript; update it together with `Package.resolved`.

## Verified SDK facts

- **Parakeet local loading.** `AsrModels.loadLocal(from:version: .ultra)` loads the compiled `.mlmodelc`
  components and `parakeet_v3_vocab.json` from the directory it's given. It doesn't download anything or resolve
  a repository name. We never call `downloadAndLoad`.
- **Parakeet timing.** `ASRResult.tokenTimings` are in seconds, relative to the samples passed in.
  - The token strings are SentencePiece pieces with `▁` replaced by a leading space.
  - `text` is exactly the tokens joined together and trimmed; no normalisation is applied when the trait is off.
    The adapter rebuilds the text from the tokens with byte offsets and checks it against `text`.
  - Starts are `(emission frame − 1) × 80 ms`. Ends are `start + TDT duration`: a model estimate, not a measured
    word end.
- **Parakeet long audio.** Outer units of 60–120 s go through `AsrManager.transcribe(_:decoderState:)`. FluidAudio
  handles its own 15 s internal windows and stitching (`ChunkProcessor`). We use `parallelChunkConcurrency: 1`.
- **Qwen local loading.** `Qwen3ASRModel.fromModelDirectory` and `Qwen3ForcedAlignerModel.fromModelDirectory`
  **write `tokenizer.json` into the directory they're given**. The worker therefore loads from
  `Models/.runtime/<id>-<rev>/`, a folder of symlinks to the verified snapshot, and the snapshot is never modified
  (confirmed). `AutoTokenizer.from(modelFolder:)` reads locally.
- **Qwen generation.**
  - `generate(audio:maxTokens:…)` shares one token budget across its own chunks. We bypass that: each window is
    a single call with `chunkDuration` larger than the window.
  - Running out of the budget shows up as `generationTokens >= maxTokens` → `tokenBudgetExhausted`.
  - The greedy repetition backstop (24 tokens with ≤ 3 distinct values) stops without reporting it, so the adapter
    detects a repetitive tail itself → `repetitionStop`.
  - Either result triggers one retry with 8–14 s windows. If that still fails, the revision is marked `partial`.
- **Qwen language.** When the language can't be parsed, the library falls back to `"English"`. We can't tell that
  fallback apart from a real detection, so we flag "English" on mostly non-Latin text as inconclusive.
- **Aligner.**
  - It returns one item per token of its own tokenisation: kept characters are letters, digits and `'`; each CJK
    ideograph is its own token; Chinese mode splits on every other character. Times are in 80 ms classes, made
    monotonic with a longest-increasing-subsequence (LIS) fix.
  - `AlignmentMapper` rebuilds those tokens with byte ranges and pairs them in order (1:1, else by longest common
    subsequence), so a repeated word can't borrow another occurrence's time.
  - The Swift aligner uses the space tokenizer for Japanese and Korean, which the upstream code itself flags as
    wrong. We therefore claim fine timing for 9 languages (zh, yue, en, de, es, fr, it, pt, ru), not the model's 11.
- **Build.**
  - MLX's Metal shaders need the Xcode **Metal Toolchain** component (`xcodebuild -downloadComponent MetalToolchain`;
    `mise run doctor` checks for it).
  - mlx-swift declares a SwiftPM build-tool plugin (`CudaBuild`), and swift-syntax brings macros. Command-line
    `xcodebuild` refuses both until they're validated, so the mise tasks and `release.sh` pass
    `-skipPackagePluginValidation -skipMacroValidation`. These trust the pinned revisions.
  - `swift build` can't build MLX; use `xcodebuild` (the app, or `speech-tool`, below).

## Process and packaging

- `MyScreenArtSpeech.xpc` is embedded in `Contents/XPCServices`. It's signed with the app's identity and uses the
  Hardened Runtime with no exception entitlements.
  - It accepts connections only from our team ID (`setCodeSigningRequirement`).
  - It exits when its connection ends, so cancelling a job or releasing an idle service returns all Core ML and MLX
    memory to the system.
  - Its resources include `mlx-swift_Cmlx.bundle` (the Metal library), `FluidAudio_FluidAudio.bundle` and
    `MyScreenArtKit_SpeechCore.bundle` (the catalogue).
  - Debug service size: 100 MB.
- Protocol: JSON `WorkerRequest`/`WorkerResponse` inside one XPC method, with a 16 MB message cap. Audio moves as
  a path to the prepared `.f32` file plus sample ranges.
- The worker validates every path: models only as verified directories under the models root, runtime files only
  under `.runtime/`, audio only as `.f32` files inside a recording's `cache/transcription/`.
- The client replays the last `load` when the service is relaunched (after a release, a crash or a memory-pressure
  recycle).
- `shutdown` is answered outside the inference actor. Cancelling a job invalidates the connection and the service
  exits, stopping inference mid-window. The stop time hasn't been measured (see Limitations).
- Models live in `~/Library/Application Support/<app id>/Models/` and are shared by all Dev worktrees.

## Tools

```bash
# Build (Release) — xcodebuild, because MLX's Metal code doesn't build with `swift build`:
cd Packages/SpeechEngines && xcodebuild -scheme speech-tool -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/stt-dd -skipPackagePluginValidation -skipMacroValidation build
T=/tmp/stt-dd/Build/Products/Release/speech-tool
$T import-models <dir-from-make-catalogue.py --download> <models-root>     # verify + install from disk
$T transcribe <pkg.msarec> <models-root> --engine parakeet|qwen [--language xx] [--fresh] [--cues] [--out rev.json]
$T compare-aligners <pkg.msarec> <models-root> <other-aligner-dir> [--out both.json]
swift scripts/dev/make-sample-recording.swift <dir> --speech "…"          # speech fixture (macOS `say`)
swift scripts/speech/make-timing-fixture.swift <pkg> "<text>"             # speech + ground-truth phrase starts
scripts/speech/timing-report.py <rev.json> <pkg>/speech-words.json        # boundary error vs ground truth
```

## Measurements (2026-09-27)

Setup:
- Apple M5 Max with 128 GB, macOS 26.6.2.
- Release `speech-tool`; the pipeline runs in-process. It's the same code as the XPC service, which the app
  exercised end to end in Debug.
- Synthetic English speech (macOS voices). This is not a substitute for accented or noisy human speech (see
  Limitations).
- 16 GB-Mac figures still need measuring on that hardware.

| | Parakeet Ultra | Qwen (1.7B 8-bit + aligner 8-bit) |
|---|---|---|
| 15-minute recording (12 min of speech), fresh run | 4.9 s (**183× real time**) | 24.9 s (**36× real time**): recognition 17.9 s, alignment 6.2 s |
| Model load (warm Core ML cache / MLX) | 0.15 s | 0.5 s recogniser + 0.6 s aligner |
| First load after install (Core ML compiles for the Neural Engine) | 9.8 s | — |
| Peak process memory | 219–238 MB | 2.61 GB (one model resident at a time) |
| Recognition (2,043 words; normalising "we're"→"we are", "four K"→"4K") | 0 errors | 0 errors apart from numbers written as words ("Part one") |
| Word-start error vs ground truth (315 phrase-initial words) | median 212 ms, p95 303 ms (see below) | **median 27 ms, p95 67 ms**, max 112 ms |
| Aligner 8-bit vs BF16 (4,138 boundaries, same recognition) | — | median 0 ms, p95 0 ms, max 80 ms (one class) → **8-bit ships** |

Further figures:
- **App end to end** (Debug XPC, 40 s fixture): Settings downloaded and installed the Parakeet model (632 MB) in
  under 20 s on this connection. "Generate Subtitles" produced 9 cues; "Regenerate with Qwen" produced a candidate
  that was adopted with the edits carried over. The service process had exited after each job.
- **Playback cost** (`msa-tool play`, 1600×900 @ 30 fps, 20 s): subtitles on 7.0 % of a core and 177 MB; off 6.6 %
  and 172 MB. Both at 29.8–29.9 fps.
- **Export:** subtitles are burned in by `FrameRenderer`. A 1080p H.264 export of 40 s took 2.9 s, the same as without subtitles.

### Parakeet start-time bias

Against the Qwen aligner on the same audio (1,939 words paired by time), Parakeet's word starts are early:
- **median −180 ms after a pause** (p95 |Δ| 280 ms);
- **median −50 ms mid-phrase** (p95 |Δ| 240 ms).

The phrase-initial ground truth above measures the "after a pause" case, which is why its median error is 212 ms.
The bias depends on context (TDT emits the word boundary into the preceding silence), so no constant correction is
applied.

In practice:
- subtitles after a pause appear a little early, which is conventional;
- a word cut starting after a pause removes some silence before the word, which is harmless;
- mid-phrase cuts can clip about 50 ms of the previous word's tail.

Qwen's aligner has no such bias. Parakeet timing is labelled `tdt`, "structurally valid", and it isn't claimed to be
acoustically exact.

## Seams (found by the long-file benchmark)

The first long run duplicated words at Parakeet's outer seams ("…Part 15. Today / Today we…"). Changing to strict
start-ownership then dropped some words that only the next window had heard through its context audio. The shipped
rule, `TranscriptAssembler.resolvedUnits`:
- cuts land in the quietest 200 ms stretch rather than the quietest 20 ms frame;
- each window owns the words that start on its side of the cut;
- two copies of the same moment keep the later window's;
- a word only the neighbour heard near the cut is added when the owner has no word within 0.3 s and no word with
  the same text within 1 s;
- words heard within 0.2 s of a window's audio edge are ignored as cut-off fragments.

Result: 0 duplicated and 0 lost words across all 7 seams of the 15-minute fixture. Unit tests cover both
failure modes.

## Limitations and checks not performed

- **Notarised build not tested.** I ran the XPC service from signed Debug builds and `speech-tool` from a Release
  build. I haven't run `release.sh` (Developer ID, notarisation). Run it before shipping, then test on a clean
  Apple silicon Mac with the network off.
- **Not measured on a 16 GB Mac.** Qwen peaks at about 2.6 GB in the service. Memory-pressure handling (pause and
  recycle the service) is implemented but hasn't been exercised under real pressure.
- **Real-speech fixtures.** Accented, noisy, music-bed, Japanese/Chinese and code-switching fixtures don't exist
  yet. None are checked in because none are redistributable.
- **Two-hour recordings.** The pipeline's memory is bounded by the window size (prepared audio is memory-mapped and
  windows are copied out one at a time), but only a 15-minute file was measured.
- **Cancellation stop time** and the playback admission hold weren't measured with instruments. Both are
  covered by unit tests and code paths only.
- **Language detection.** Qwen's fallback to "English" is only partly detectable. Aligning an unknown language is
  skipped (the timing stays coarse), never forced to English.
- **Japanese and Korean fine timing** is disabled until the Swift aligner tokenises them properly.
