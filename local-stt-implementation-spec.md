# Local speech-to-text for the video editor

**Implementation specification for the coding agent**  
**Decision date / documentation checked:** 26 September 2026  
**Selected approach:** Parakeet Ultra via FluidAudio/Core ML, plus optional Qwen3-ASR via MLX Audio Swift, behind one application-owned transcription service.

> Implement this in the existing application. Preserve its UI, media engine, project format, and editing conventions. Do not build a replacement editor. Deliver both real inference backends, not just interfaces or mock results. The product decisions below are intentional; resolve library-specific details against pinned source code rather than inventing SDK APIs.

## 1. Scope and decisions

Build offline transcription of recorded/imported media for transcript search, captions, and transcript-driven editing. Optimise for ordinary Apple Silicon hardware, with a 16 GB Mac as the primary memory-constrained test machine. This is an engineering target, not a measured minimum requirement.

| Decision | Implementation |
|---|---|
| Default recogniser | Parakeet Ultra, using FluidAudio and its Core ML implementation. |
| Optional recogniser | Qwen3-ASR 1.7B, using an 8-bit MLX checkpoint through MLX Audio Swift. |
| Qwen word/character timing | Separate Qwen3-ForcedAligner 0.6B pass, using MLX Audio Swift. Start with its documented 8-bit checkpoint and validate timing against BF16 before release. |
| User-facing model options | Two recognisers, not a long list of sizes, quantisations, and runtimes. Treat the aligner as a Qwen feature dependency. |
| Inference location | On the user's Mac. No cloud fallback, Python environment, PyTorch runtime, local HTTP server, or user-installed CLI. A bundled native worker is allowed. |
| Downloads | Models download on demand with explicit user consent. Installing the app must not download both recognisers automatically. |
| Scheduling | One inference operation at a time across recognisers and alignment. Never keep both recognisers loaded merely because both are installed. |
| Data contract | One application-owned transcript format, independent of either SDK. |
| Timebase | Store recognition timing in original source-media coordinates; derive edited-timeline timing separately. |
| User corrections | Preserve separately from immutable recognition output. Retranscription creates another revision. |

The chosen native integrations and checkpoint variants are documented upstream. FluidAudio added explicit Ultra support in v0.17.3. MLX Audio Swift documents Qwen recognition and forced alignment. These are integration choices, not a claim that one recogniser always has better accuracy. [^S1][^S2][^S3][^S4][^S5]

**Not in the initial scope:** live streaming during recording, translation, speaker diarisation, source separation, voice cloning, model training, arbitrary user-supplied models, Windows/Linux support, or a new transcript-editing product beyond the editor's existing capabilities. Keep those extensions possible without implementing them now.

## 2. Repository discovery and integration placement

Earlier project context used **Electron/React/TypeScript plus a Rust media engine** for a macOS screen recorder/editor. The current repository has not been inspected for this document. Start by checking its actual implementation; do not assume a native Swift UI or rewrite the app to create one.

Inspect the repository's agent instructions, package manifests, native targets, project schema, media decoding, IPC, job queue, build pipeline, and signing configuration. Produce a short implementation note identifying where this feature will live.

### Default for the earlier Electron/Rust architecture

Use a **bundled Swift inference worker**, launched and supervised by the existing trusted host process. Prefer the Rust service if it already owns media jobs; otherwise use the Electron main process. There must be exactly one owner of the transcription queue and worker lifecycle.

```text
Editor UI / existing renderer
          |
Existing trusted host and job queue
  - project storage and edit history
  - model download/catalogue management
  - audio preparation and source-time mapping
  - transcript revision commits
          |
Private local IPC; no listening HTTP port
          |
Bundled Swift inference worker
  - ParakeetAdapter -> FluidAudio / Core ML
  - QwenAdapter     -> MLX Audio Swift / MLX
  - QwenAligner     -> MLX Audio Swift / MLX
          |
Application-owned result objects
          |
Shared transcript UI, captions, search, timeline mapping
```

The Swift worker is an internal packaged component, not something users install or operate themselves. Do not embed model execution in the renderer. Avoid adding a Rust-to-Swift FFI layer when an existing process boundary is simpler.

**If the current repository is already native Swift:** use the same application-owned service and adapters in-process, off the main actor. Reuse an existing worker/XPC boundary when available. Do not introduce another process solely to match the diagram.

### Build compatibility check

The checked FluidAudio v0.17.3 manifest declares macOS 14 and Swift tools 6.0. The checked MLX Audio Swift manifest declares macOS 14 and **Swift tools 6.2**, despite older requirements text in its README. Use the actual manifests and resolved dependency graph to determine the toolchain and deployment target. Start the integration spike with Swift 6.2 or a compatible newer toolchain. Do not silently raise the application's minimum macOS version. [^S6][^S7]

Pin FluidAudio to v0.17.3 for the first reproducible integration, unless a reviewed fix is necessary. Pin MLX Audio Swift to an immutable, tested commit; this document does not prescribe an unverified commit hash. Commit `Package.resolved` and record all resolved revisions. Do not ship a floating `main` dependency.

## 3. Required modules and ownership

These names describe responsibilities, not a mandatory new directory hierarchy. Reuse equivalent existing components.

| Module | Responsibility |
|---|---|
| `TranscriptionService` | Public application interface, capability checks, job submission, cancellation, retry, progress, and commit coordination. |
| `ModelStore` | Catalogue, immutable manifests, downloads, verification, install state, removal, and model leases. |
| `AudioPreparation` | Decode selected audio, select/mix tracks explicitly, resample, cache prepared audio, preserve its source-time map. |
| `InferenceWorkerClient` | Worker startup/handshake, typed IPC, crash detection, cancellation, and bounded restarts. Omit for a fully in-process host. |
| `ParakeetAdapter` | Load Ultra, recognise audio, decode token timing semantics, return canonical transcript data. |
| `QwenAdapter` | Load Qwen recogniser, bounded recognition, detect incomplete output, return text and coarse segment provenance. |
| `QwenAlignmentAdapter` | Align exact recognised text to corresponding audio; map alignment output into canonical timed units. |
| `TranscriptRepository` | Immutable raw revisions, alignment revisions, user corrections, migrations, and atomic writes. |
| `TimelineTranscriptMapper` | Map source spans through clip placement, trimming, duplication, and supported retiming. |
| `CaptionBuilder` | Derive display cues from a selected transcript revision and timeline; export through existing subtitle infrastructure. |

SDK-specific result objects, MLX arrays, Core ML objects, SDK model IDs, and mutable decoder state must not leak into the editor UI or project model.

## 4. Canonical transcript contract

Use the project's existing serialization and type-generation conventions. The following TypeScript expresses the intended **application data contract**, not upstream SDK types or a complete drop-in implementation.

```ts
// Decimal Int64 string avoids precision loss across Swift/Rust/JavaScript.
export type MediaTime = {
  value: string;
  timescale: number; // positive integer
};

export type MediaRange = {
  start: MediaTime;
  duration: MediaTime; // non-negative; range is half-open
};

export type Timing = {
  sourceRange: MediaRange;
  method: "tdt" | "forcedAlignment" | "coarseChunk" | "manual";
  validation: "unchecked" | "valid" | "needsReview";
};

export type TranscriptUnit = {
  id: string;
  // Half-open UTF-8 byte range into the containing segment's rawText.
  utf8Start: number;
  utf8End: number;
  kind: "word" | "character" | "subword" | "punctuation";
  timing: Timing | null;
  languageTag: string | null;
  backendScore: number | null; // not a cross-model confidence probability
  warnings: string[];
};

export type TranscriptSegment = {
  id: string;
  sourceRange: MediaRange;
  rangeMeaning: "speech" | "processingWindow";
  rawText: string;
  languageTag: string | null;
  units: TranscriptUnit[];
};

export type ModelIdentity = {
  catalogueID: string;
  repository: string;
  revision: string;
  manifestDigest: string;
  quantisation: string;
};

export type TranscriptRevision = {
  schemaVersion: 1;
  id: string;
  parentRevisionID: string | null;
  sourceMediaID: string;
  audioIdentityHash: string;
  recogniser: ModelIdentity;
  aligner: ModelIdentity | null;
  implementationFingerprint: string;
  optionsFingerprint: string;
  sourceCoverage: MediaRange[];
  segments: TranscriptSegment[];
  status: "partial" | "complete";
  warnings: string[];
};
```

Persist the full canonical options and implementation/version metadata alongside their fingerprints. Hashes alone are insufficient for debugging or reproduction. Give raw recognition and alignment artifacts their own identities so alignment can be retried without recognising again.

### Contract rules

- All persisted timings use the source media's normalized presentation timeline, not wall-clock time, decoder time, temporary-file zero, or the current edited timeline. The source identity defines that timeline and its origin.
- Use rational time or the editor's existing equivalent. Use integer sample positions for prepared audio. Convert floating-point SDK seconds once, with an explicit rounding rule. Apple's media APIs use rational `CMTime`; preserve that precision at integration boundaries. [^S8]
- Validate finite times, positive timescales, non-negative durations, valid UTF-8 boundaries, and containment within the source interval. Reject significant out-of-range output; only clamp sub-sample rounding errors under a documented tolerance.
- `validation: "valid"` means structural checks passed. It does **not** certify that the model heard the correct word or found its exact acoustic boundary.
- Missing timing is allowed. Never manufacture word timestamps by evenly distributing text across a chunk.
- SDK tokens are not automatically words. Preserve language-aware segmentation and punctuation. Japanese and Chinese must not depend on splitting text on spaces.
- Preserve the recognised text exactly in `rawText`. Display corrections, casing preferences, subtitle wrapping, and number formatting belong in separate layers.
- Word start order should be consistent within a single speech lane, but do not prohibit legitimate overlap across different audio tracks. Do not silently reorder units to hide broken timing.
- Keep nullable backend scores for diagnostics only. Do not compare Qwen and Parakeet scores as interchangeable confidence values.
- Keep source track/channel identity in the audio recipe. Separate microphone and system-audio tracks are not automatically speaker identities.

Add schema validation at every persisted-data and IPC boundary, plus migration tests before changing an existing project schema.

## 5. Audio preparation and time preservation

Reuse the application's existing decoding stack. An existing Rust/FFmpeg pipeline should not be duplicated just to use AVFoundation; a native Swift app can use AVFoundation's asset-reading facilities. In either case, preserve presentation timestamps and stream offsets rather than assuming every decoded track starts at zero. [^S9]

### Prepared-audio contract

Prepare correctly decoded **16 kHz mono audio**, delivered to the adapters as Float32 samples or a properly parsed equivalent PCM file. FluidAudio documents this input contract and Qwen's Swift implementation also specifies 16 kHz. Do not feed 44.1/48 kHz samples while merely labelling them 16 kHz. [^S10][^S11]

A prepared asset must carry:

- Source content identity, selected stream/track/channel IDs, and any mix recipe.
- Sample rate, sample count, channel count, sample format, and normalization/decoder version.
- A mapping from prepared sample intervals to source presentation intervals.
- Exact extraction range and any padding, trimming, or discontinuity information.
- An integrity identity used in recognition and alignment cache keys.

For a contiguous interval, the conversion is conceptually:

```text
source time = source origin + prepared sample index / 16,000
```

For concatenated or discontinuous media, use an explicit piecewise map; a single offset is insufficient. Do not remove silence and then pretend the remaining samples still form one continuous source interval.

### Required behavior

Decode incrementally to disk-backed audio or bounded buffers. Never require a whole two-hour recording to be materialized as one SDK tensor. Preserve valid media duration separately from padding added for model minimum-input requirements.

Prefer a clean narration/microphone track when that is the existing project convention, but show the selected source to the user. Do not silently transcribe a final mix containing background music when an isolated voice track was selected. Keep independent microphone/system-audio tracks separate unless the user deliberately requests a mix.

Use an explicit downmix/channel policy. Include stereo with out-of-phase channels in tests: naive averaging can erase speech. Do not silently apply denoising, loudness compression, or other speech-changing processing in v1. Any later preprocessing must be versioned and included in the audio identity.

Reuse proper audio readers; do not parse WAV by dropping a fixed header length. Test compressed audio, metadata-bearing WAV files, non-zero stream offsets, and codec priming. Preserve decoder-provided timing rather than applying a guessed universal offset.

No microphone or speech-recognition permission prompt is needed merely to process an already-authorized file through this local-model feature. Preserve the app's existing recording permissions and file-access model; do not request additional capture permissions as a workaround for file decoding.

## 6. Backend integration

### 6.1 Parakeet Ultra adapter

Use `FluidInference/parakeet-ultra-coreml` through FluidAudio. Select **`.ultra` explicitly**; the documented library default remains `.v3`. The Ultra release uses an ANE-oriented Core ML encoder path. Treat compute-unit settings as preferences and observe actual behavior; do not promise that all processing runs exclusively on the Neural Engine. [^S1][^S2][^S16]

The upstream convenience bootstrap is `AsrModels.downloadAndLoad(version: .ultra)`. That is useful for an isolated integration spike, **not** the production offline model-loading contract. Locate and exercise the local-model loading path in the pinned release, then connect it to `ModelStore`. If it needs a small extension, keep it inside the adapter and document the patch rather than allowing uncontrolled downloads during transcription.

Use the SDK's existing long-form decoding and stitching where practical. Do not recreate its mel frontend, TDT decoder, vocabulary handling, or internal inference-window logic.

The adapter must return text plus the available token timing metadata. Inspect actual returned values and units before producing word spans. Verify token/subword grouping, punctuation, start/end semantics, and whether timing is local to a call or already offset. Timing emitted by TDT is a model estimate, not a guarantee of phonetic word boundaries. End times inferred from neighboring starts must be marked as estimated/needs-review rather than presented as measured endpoints.

Reconcile any SDK text normalization with token timing explicitly. For example, multiple spoken-number tokens may correspond to one displayed numeral. Do not derive byte offsets by assuming the formatted result has a one-to-one relationship with decoder tokens; preserve the mapping or mark the affected span for review.

For bounded memory and cancellation, prefer a verified incremental SDK path. Otherwise feed bounded outer work units, initially targeting roughly 60–120 seconds with safe boundaries, while allowing the SDK to manage its smaller internal windows. Persist completed outer units. Outer boundary handling is the adapter's responsibility; do not run two competing stitchers over the same internal boundaries.

### 6.2 Qwen recogniser adapter

Use **`mlx-community/Qwen3-ASR-1.7B-8bit`**. Import the STT/core products needed by the worker, not the all-in-one UI/TTS product. Respect the transitive dependencies that the selected package actually requires. [^S3][^S4][^S5]

The checked Swift source exposes `Qwen3ASRModel.fromModelDirectory(_:)`; use a verified local directory instead of a repository-name loader in production. Start with greedy decoding, explicit bounded generation limits, and no creative text rewriting. Keep user vocabulary/context opt-in and versioned. [^S11]

Own bounded recognition work units in the Qwen adapter. Suggested starting settings are 20–30-second chunks, with a 60-second hard cap and cuts near low-energy boundaries when available. These are proposed app defaults, not Qwen's model limits. No additional VAD model is required for the initial implementation.

Do not trust the library's long-audio convenience call to guarantee complete output. The checked implementation manages a generation-token budget across chunks; the adapter must detect exhaustion or otherwise incomplete output. Record the termination/coverage evidence supported by the pinned implementation. Retry an affected window once with smaller windows or an adjusted safe token budget; never silently return a truncated transcript as complete. [^S11]

Plain Qwen recognition output can supply processing-window ranges; those ranges are **not word timestamps**. Persist them as `rangeMeaning: "processingWindow"`. The UI may show the text immediately while alignment is pending.

### 6.3 Qwen alignment adapter

Use **`mlx-community/Qwen3-ForcedAligner-0.6B-8bit`** initially. The native implementation documents this checkpoint family and exposes a local-directory loader. The checked aligner output consists of text items with start/end times; verify units and text normalization against fixtures. Do not write a second independent aligner. [^S4][^S14][^S17]

Initial memory-conscious execution:

```text
1. Load Qwen recogniser.
2. Recognise bounded audio windows and persist raw text plus window references.
3. Release the recogniser and wait for pending inference work to finish.
4. Load the Qwen aligner.
5. Align each exact text/window pair; persist alignment results incrementally.
6. Merge boundaries, validate timings, and commit the completed revision.
```

Do not switch models for every 30-second chunk on a 16 GB machine. Run the recognition and alignment phases separately. Use disk-backed window references, not retained audio tensors.

The official aligner supports inputs of up to five minutes; our smaller recognition windows stay below that limit. Keep an explicit guard against oversized alignment requests. Align the exact text recognised from the corresponding audio, not a cleaned-up summary or text from a different chunk. [^S13]

Map aligner items back to the original segment text monotonically, accounting for punctuation, normalization, repeated words, and language-specific segmentation. Do not use independent first-occurrence string searches. If the mapping is ambiguous or incomplete, retain recognition and report an alignment mismatch instead of attaching timings to the wrong text.

If a user corrects actual spoken words, allow realignment of the affected interval with surrounding context. A stylistic rewrite or an inserted unspoken sentence must not acquire fabricated acoustic timing.

Compare the 8-bit aligner with the documented BF16 checkpoint on the same timing fixtures. If quantisation produces unacceptable regressions, use BF16 for the shipped aligner without adding another user-facing model selector. Record the chosen checkpoint and measured memory trade-off. This document does not claim the two precisions have identical timing accuracy.

### 6.4 Language capability rules

Qwen recognition supports 30 languages. Its official forced aligner supports this narrower set of 11: **Chinese, English, Cantonese, French, German, Italian, Japanese, Korean, Portuguese, Russian, and Spanish**. Parakeet Ultra retains its 25-language v3 coverage. Build capabilities from the reviewed model metadata, not a shared assumption that all operations support every recognition language. [^S12][^S13][^S16]

Keep separate capability fields for recognition, language hints/detection, fine timing, and language-specific alignment. Use canonical language tags internally and adapter-specific names at the SDK boundary. Do not silently collapse Cantonese into Mandarin or change the requested writing system.

For languages outside Qwen's alignment set, allow transcription with explicitly coarse timing. Disable word-driven cuts and karaoke-style word highlighting until supported fine timing or manual timing exists. Do not offer a whole-chunk timestamp as if it precisely locates each sentence. Permit plain-text export; make coarse caption export an explicit, clearly labelled choice.

For unknown or mixed-language segments, do not default alignment silently to English. Use reliable segment language information when available; otherwise preserve text and mark timing unavailable/needs-review. Code-switching must have its own test coverage before claiming fine timing support.

### 6.5 Chunk seams and silence

Store each work unit's valid source coverage and any left/right context independently. Add chunk offsets exactly once.

Where overlapping windows have fine timings, merge only competing hypotheses for the **same temporal interval**. Retain each unit's provenance, compare text and timing together, and use deterministic ownership at the seam. Repeated phrases at different times are not duplicates. Never apply global text deduplication.

For text-only Qwen output, prefer non-overlapping, silence-adjacent ownership windows rather than pretending word timing exists to resolve overlap. Keep uncertain seam regions visible in diagnostics and test forced cuts through speech. Do not discard content just because its text resembles a previous chunk.

On an ambiguous seam, permit one small seam-repair transcription/alignment task before commit. Keep repair bounded and cacheable. Do not recursively retranscribe the entire source.

Test silent clips, music-only sections, long pauses, repeated words, and speech at the final sample. Low energy is a boundary hint, not permission to delete quiet speech. Padding must not generate committed words beyond valid media duration.

## 7. Model catalogue, downloads, and offline loading

### Initial catalogue

| Application ID | Repository | Purpose |
|---|---|---|
| `parakeet-ultra-coreml` | `FluidInference/parakeet-ultra-coreml` | Default recogniser and native timing. |
| `qwen3-asr-1.7b-8bit` | `mlx-community/Qwen3-ASR-1.7B-8bit` | Optional recogniser. |
| `qwen3-aligner-0.6b-8bit` | `mlx-community/Qwen3-ForcedAligner-0.6B-8bit` | Qwen fine-timing dependency for supported languages. |

These repositories and variants are documented. The implementation must fill in **real immutable revisions, file inventories, sizes, and checksums**. Do not ship placeholder SHAs or invent a download URL from a model's friendly name. Download size is not runtime memory usage. [^S4][^S5][^S16][^S17]

Each manifest must include repository/revision, required files, byte sizes, SHA-256 digests, format/quantisation, runtime compatibility, minimum OS/architecture checks, source/converted-model attribution, license files, and capability metadata. Resolve any shared files explicitly; do not fetch a vocabulary from floating `main` while pinning the weights.

Use the app's existing non-purgeable application-support location for model installations. Keep transient downloads, derived runtime caches, and prepared audio separate. Do not store model weights in project documents or write into the signed `.app` bundle.

### Download/install transaction

1. Show the real required download and installed sizes before consent. For Qwen fine timing, include recognition plus alignment dependencies.
2. Check available disk space, including staging/unpacking overhead. Download only required files into a staging directory.
3. Support cancellation and restart; resume only when the server's entity identity/range response is compatible with the expected file.
4. Verify bytes, hashes, file inventory, and archive paths. Reject path traversal and symlinks escaping the installation root.
5. Atomically promote a complete verified installation. Never mark a partially populated folder as installed.
6. Keep an active-use lease so deletion or updates cannot race inference. Remove unused versions only under a safe cleanup policy.

Expose `notInstalled`, `downloading`, `verifying`, `installed`, `preparing`, `ready`, `failed`, and `removing` states. A completed download is not necessarily a warmed runtime. Do not redownload verified models because a later network request failed.

After installation, local recognition/alignment must work with networking unavailable. The worker receives only approved model directories; do not invoke a repository-name convenience loader or tokenizer code that downloads missing files behind the user's back. Both checked Qwen classes have local-directory loading paths. Audit their complete file requirements, including tokenizers and configurations. [^S11][^S14]

If an SDK creates derived tokenizer or compiled files, supply a validated runtime working directory or dedicated derived cache. Do not let it mutate the authoritative checksum-verified model snapshot unnoticed. Deleting caches must not delete user's transcripts.

### Attribution and license inventory

The checked Ultra upstream/Core ML model cards identify **CC-BY-4.0**; the selected Qwen MLX checkpoint cards identify **Apache-2.0**. Do not describe all weights as MIT merely because an integration library uses that license. Record the exact upstream and conversion notices, preserve license/notice files, and expose model attribution in the app's acknowledgements. Review the actual files for the pinned revisions before distribution. [^S5][^S16][^S17][^S18]

## 8. Job lifecycle, IPC, cancellation, and resources

The service owns one queue, with immutable per-job model choice, source identity, options, generation ID, and source coverage.

```text
queued -> waitingForModels -> preparingAudio -> loadingRecognizer
       -> recognizing -> unloadingRecognizer -> loadingAligner
       -> aligning -> validating -> committing -> completed
```

Skip alignment states for Parakeet or Qwen text-only jobs. Every active state can transition to `cancelling`, `cancelled`, or `failed`. Pausing is explicit: stop scheduling new work and pause at a safe boundary. Do not imply an in-flight native kernel can always be suspended immediately.

Progress events must describe real stages and completed work. Use known download bytes, decoded samples, recognised source coverage, and aligned coverage. Model initialization can be indeterminate. Do not show 100% until validation and atomic commit finish. Do not derive completion solely from generated token count.

### Bundled-worker protocol

Use the existing private IPC mechanism where practical. For a subprocess without an existing protocol, length-framed messages or newline-delimited JSON over private pipes are sufficient. Include a protocol version, request ID, job ID, generation ID, and sequence number. Define commands for handshake/capabilities, local-model loading, recognition, alignment, cancellation, unloading, and shutdown.

Use file references or bounded buffers for audio, never multi-hour base64 payloads. Validate all paths against host-authorized media/model locations. The renderer must not be able to ask the worker to read an arbitrary file or load arbitrary code.

Keep control-message handling responsive independently of synchronous inference. Serializing GPU/model work is appropriate; blocking the same serial executor that must receive cancellation is not. Protect SDK state with one inference owner and materialize plain result data before crossing concurrency boundaries. Do not blanket-add unchecked concurrency annotations to silence compiler errors.

SDK logging must not corrupt the wire protocol. If stdout carries protocol messages, redirect/capture third-party stdout separately or reserve a dedicated protocol descriptor. Drain logs and results concurrently with size limits to prevent pipe deadlocks. Test startup messages, multiline text, Unicode, partial frames, and malformed/oversized input.

### Cancellation and crash behavior

Cancellation requests must be acknowledged promptly and suppress all later commits for that generation. Check cancellation before loading, between windows, inside supported decoding callbacks, before alignment, and immediately before commit. Do not free model buffers while native work is still using them.

If a worker cannot stop within a tested grace period, terminate the worker and restart it on the next job. Keep project storage outside that worker. A cancelled or crashed generation must never overwrite a newer transcript. Permit at most one automatic retry for an eligible transient failure; never loop on a reproducible crash.

For an in-process integration, document any uninterruptible operation and keep units short enough for acceptable cancellation. Do not claim immediate cancellation if the SDK does not support it.

### Memory and playback policy

Keep one recogniser or aligner resident by default. Release GPU results and cached decoder state between phases; verify memory behavior empirically rather than assuming dropping a Swift reference immediately returns all memory. Recycle an idle worker if that is the most reliable way to reclaim its allocation pools.

On memory pressure, stop admitting work, checkpoint completed units, and unload or restart safely. Do not silently change the user's chosen model. Offer a supported alternative explicitly when needed.

Reuse the editor's playback/export scheduling signals. Pause or reduce admission of new Qwen work during demanding playback/export; apply the same policy to Parakeet when measurements show contention. ANE-oriented inference may reduce direct GPU competition, but it still uses system resources. Do not promise zero impact on playback.

Handle application quit, sleep/wake, and model removal during queued jobs. Persist checkpoints sufficient to restart at completed boundaries, but do not serialize opaque live SDK/GPU state.

## 9. Source-to-timeline mapping and editing

Keep source recognition reusable across placements of the same source. For a clip with a positive constant playback rate:

```text
timelineTime = clipTimelineStart + (sourceTime - clipSourceIn) / playbackRate
```

For example, a clip starts at timeline 10 seconds, its source in-point is 120 seconds, and its rate is 2x. A word at source 122 seconds maps to timeline 11 seconds. This is an arithmetic mapping, not a new recognition job.

Intersect a unit's source range with the clip's visible source range before mapping it. Preserve clip-instance IDs: two placements of the same source must produce two distinct timeline occurrences without duplicating the raw transcript.

Use the editor's existing piecewise mapping for speed ramps. Do not apply the constant-rate formula to variable-speed material. Reverse playback, freezes, discontinuities, and complex retiming require explicit capability handling; disable transcript-driven edits for unsupported cases rather than producing incorrect cuts.

Do not retranscribe because a clip moved, a caption style changed, or its volume changed. A changed source track, replacement media, selected mix, or recognition preprocessing recipe must change the audio identity. If a future feature transcribes a rendered sequence rather than original media, give that derived audio its own identity and timeline map.

### Corrections and retranscription

Persist raw recognition separately from user edits and derived captions. Link corrections to source/time anchors and revision-specific unit IDs; raw character offsets alone are not stable across retranscription.

“Retranscribe with Qwen” creates a new candidate revision. Keep the current edited transcript intact until the user chooses to adopt or merge the candidate. Preserve the previous revision and undo history. Reapply only demonstrably unambiguous corrections; surface conflicts instead of silently discarding them.

Alignment updates timing, not the user's editorial wording. Inserted unspoken words can inherit an explicitly manual display range, but must not masquerade as acoustically aligned units.

For transcript-driven cuts, generate existing timeline edit operations with undo/redo. Do not destructively modify source media. Use the selected clip instance and lane, not just a word's source timestamp, to decide where an edit applies.

### Caption derivation

Build cues from the selected transcript/edit layer and then map to the edited timeline. Keep line breaks, maximum cue lengths, punctuation display, timing padding, and visual style separate from raw recognition.

Never let a cue cross a removed interval or jump cut without splitting it. Word highlighting requires usable fine timing. Plain-text and coarse-timing modes must remain visibly distinct.

Reuse existing subtitle export. Where none exists, implement UTF-8 SRT and WebVTT with proper escaping, timestamp formatting, stable cue order, and explicit handling of overlapping lanes. Display-duration adjustments must not rewrite original acoustic times.

## 10. Persistence, caching, and failure behavior

Use atomic writes and the existing project transaction mechanism. A worker returns artifacts to the host; it must not mutate the project's active transcript directly.

Maintain distinct cache identities:

```text
preparedAudioKey = hash(source content + selected streams/mix +
                        extraction range + decoding/resampling recipe + time map)

recognitionKey = hash(preparedAudioKey + recogniser manifest digest +
                      adapter/runtime versions + language/context options +
                      decoding settings + chunk/stitch policy)

alignmentKey = hash(recognition artifact + exact text + audio-window references +
                    aligner manifest digest + alignment language/options +
                    adapter/runtime versions)

captionKey = hash(selected transcript/edit revision + clip mapping + cue settings)
```

Use the project's trusted content identity system, not a filename alone. Do not reuse results after a same-path file is replaced. Avoid hashing large source files repeatedly when a validated content identity already exists.

Persist completed chunk artifacts and coverage. Resuming a job must use the same model/options or start a new revision. Mark partial results visibly; do not count skipped or exhausted chunks as complete. Successful silence is valid processed coverage with no words, not a transcription failure.

Before commit, check the job generation, source identity, project state, and current transcript parent. If the user edited or retranscribed while the job was running, save the result as a candidate rather than overwriting their changes.

Define typed failures at minimum for unsupported platform/language, unavailable fine timing, missing/corrupt models, download/disk failures, unreadable or absent audio, permission failure, model initialization, incomplete decoding, alignment mismatch, memory pressure, cancellation, worker crash, and invalid timing.

Alignment failure must preserve successful recognition. Offer retry alignment or retain a text-only result. A GPU/runtime failure must not trigger an unannounced cloud request or substitute recogniser. Delete only owned temporary files; never remove original media during failure cleanup.

Logs should contain stages, durations, counts, error codes, and model/runtime revisions—not raw audio, transcript content, or full personal file paths by default. Any diagnostic export containing user media/text requires explicit consent. Keep model-download network activity separate from inference so offline behavior is auditable.

## 11. User-facing behavior

Use simple model labels:

| Option | Suggested description |
|---|---|
| **Parakeet Ultra — Default** | Local transcription with native timing. |
| **Qwen — Multilingual** | Local transcription with broader language coverage; supported fine timing uses an additional alignment model. |

Do not label Qwen universally “best” or “most accurate.” Show supported languages, whether fine timing is available, real download size, installation state, and the selected audio source.

Remember a user's explicit model choice. For an unsupported language, explain the limitation and offer an appropriate installed/downloadable option; do not silently switch. With automatic language selection, capabilities must be checked again when language information becomes available.

Keep recognition text usable while Qwen alignment runs. Show stages such as “Transcribing” and “Adding word timing.” Make cancellation available in each active stage and keep the editor responsive. Do not expose Core ML/MLX configuration knobs in the first version unless needed for diagnostics.

## 12. Packaging and distribution

Prove the packaged runtime early. A working Xcode debug session is not sufficient.

Build the Swift worker using a supported release-build path that includes MLX's Metal resources. The checked MLX documentation discusses shader build requirements and warns against linking duplicate MLX copies into one process. Its build guidance has multiple paths; use the pinned version's verified instructions rather than assuming plain `swift build` always produces a distributable worker. [^S15]

Bundle required native libraries, SwiftPM resources, tokenization dependencies, and Metal libraries at their expected runtime locations. Build/sign embedded executables through the application's established pipeline, then validate the distributed app and notarization workflow. Apply only the entitlements actually needed; do not weaken the entire app's security to bypass a packaging error. Apple's notarization documentation is the distribution reference. [^S19]

For an existing universal app, keep Intel behavior explicit: disable these selected Apple-Silicon backends cleanly on unsupported machines rather than crashing or pretending equivalent performance. Do not change the whole application's architecture support without a separate decision.

Test from an installed app on a clean Apple Silicon Mac with no developer tools, Python, Homebrew, or pre-existing model caches. Repeat after models are installed with networking blocked, including after restarting the app. Test the real sandbox/file-access arrangement and helper resource lookup. CI unit tests without a GPU are useful, but do not replace on-device inference and packaging tests.

## 13. Test plan and release gates

### Automated tests without model downloads

Use deterministic fixtures and fake adapters to test service behavior, not to claim inference quality.

| Area | Required cases |
|---|---|
| Serialization | Int64/rational round trips; malformed values; schema migrations; UTF-8 byte-range validation. |
| Time mapping | Non-zero source offsets; trim; move; duplicate clip; 0.5x/2x rate; supported piecewise retiming; discontinuous audio maps. |
| Chunk seams | Repeated phrases at different times; overlapping hypotheses; speech crossing boundaries; final-window flushing; padding exclusion. |
| Jobs | Cancellation in every stage; late output after cancellation; concurrent edits; crash/restart; bounded retry; resume without duplicate commits. |
| Model store | Interrupted download; mismatched hash; invalid archive path; low disk; delete-while-leased; corrupted/missing tokenizer; offline cached use. |
| Editing | Corrections survive retranscription; conflicts remain visible; undo/redo; cue split at cuts; duplicate source placements. |
| Capabilities | Qwen recognition-only language; unknown language; mixed language; missing aligner; unsupported hardware. |
| IPC | Fragmented/oversized frames; Unicode; SDK stdout contamination; log backpressure; invalid requests; dead worker. |

### Real-model fixtures and benchmarks

Use redistributable or user-consented recordings. Include clean narration, accented English, technical names, Japanese, Chinese, code-switching, low volume, music/noise, stereo channel edge cases, long silence, and speech at the final boundary. Include short clips, a 10-minute clip, and a two-hour recording. Do not check private user recordings into the repository.

Measure the complete path: decoding, cold/warm model loading, recognition, alignment, merge/validation, and result commit. Report hardware, RAM, OS, build configuration, model/runtime revisions, quantisation, peak worker memory, system memory pressure, processing/audio-duration ratio, cancellation latency, and playback impact.

For accuracy, compute WER where appropriate and CER for relevant scripts, with a documented normalization policy. For timing, use manually checked word boundaries; report median/p95 boundary error on correctly matched units **and** recognition errors/alignment coverage separately. Excluding wrong words from timing must not hide their recognition failures.

**Initial performance/quality targets below are proposed acceptance criteria, not claimed benchmark results:**

- Warm full-pipeline processing should be faster than real time on the selected 16 GB reference Mac. Report recognition and alignment separately as well.
- Long-file working memory should remain bounded by model/work-unit size rather than grow with recording duration. Repeated jobs must not accumulate unreclaimed memory indefinitely.
- Target median fine-timing boundary error at or below 100 ms and p95 at or below 300 ms on the clean-speech timing fixtures. If a route misses this, investigate, flag its limitation, or disable precision-editing claims for that route; do not relabel coarse timing as fine.
- The UI must acknowledge cancellation promptly, reject cancelled output, and remain responsive during loading/inference. Measure actual stop/reclaim time and use a tested worker timeout.
- Playback/export must remain usable under the admission policy. Compare dropped frames and interaction latency against the same timeline without transcription; record the results rather than invent a universal contention percentage.
- After installation, both recognition paths and supported Qwen alignment must complete without inference-related network access.

Benchmark Qwen aligner 8-bit versus BF16 on the same clips. Do not require bit-for-bit model output across different hardware/runtime versions; require provenance, deterministic fixture logic, and measured regression thresholds.

## 14. Implementation order and definition of done

### Phase 0 — Integration and packaging spike

Inspect the repo. Resolve/pin compatible packages. Run one local Parakeet Ultra transcription and one Qwen recognition-plus-alignment from a minimal bundled worker or native target. Verify local model loading, timing units, cancellation behavior, and release Metal resource lookup. Record unresolved SDK limitations before building UI around assumptions.

### Phase 1 — Shared foundation

Implement schemas, audio/time-map contract, service/queue, model store, worker protocol, atomic artifacts, and deterministic tests. Keep changes scoped to the transcription feature.

### Phase 2 — Parakeet vertical slice

Deliver model download/install, real Ultra transcription, timing normalization, persistent transcript display, search/seek, cancellation, and long-file chunk handling. Wire into existing caption/edit features with undo support.

### Phase 3 — Qwen vertical slice

Deliver optional model/dependency installation, bounded recognition, separate alignment phase, language gates, partial-text display, and consistent canonical results. Validate quantised alignment and incomplete-generation handling.

### Phase 4 — Editing and reliability

Finish transcript revisions/corrections, clip-instance mapping, supported retiming, caption exports, cache reuse, crash recovery, low-memory handling, and performance-aware scheduling.

### Phase 5 — Release verification

Run the real-model fixture suite on target hardware. Test installed signed builds, offline behavior, fresh installs, model removal, and resource limits. Commit measured results and the exact runtime/model lock information.

**Do not stop after Phase 1 or the Parakeet slice and describe the feature as complete.** Both selected recognisers and Qwen's supported alignment path are required. If a concrete dependency blocks one piece, finish unaffected work, keep the unavailable feature disabled, and report the exact blocker rather than fabricate successful integration.

### Required handoff artifacts

- Production code for the service, both adapters, Qwen alignment, and applicable worker integration.
- Validated schemas, migrations, manifests with real revisions/hashes, and dependency lock files.
- Automated tests plus executable on-device smoke/benchmark commands using the project's conventions.
- Runtime integration notes covering actual SDK APIs, local-loading paths, concurrency limits, and build/resource packaging.
- Model acknowledgements and a privacy/offline verification note.
- A concise completion report with changed files, commands run, measured results, known limitations, and any checks that were not performed.

## 15. Evidence and implementation caveats

This is an implementation specification based on checked primary documentation and source code, **not a report of a compiled or benchmarked integration in the user's repository**. Live `main` source links can change. During Phase 0, record the tested immutable revisions and replace relevant working references with commit permalinks.

No throughput number from a GPU-server benchmark is an acceptance promise for a Mac. No checkpoint download size is a RAM estimate. No model's transcription-language list automatically establishes alignment-language support.

### Primary sources

[^S1]: [FluidAudio v0.17.3 release — explicit Parakeet Ultra support](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.3). Checked 26 September 2026.

[^S2]: [FluidAudio Parakeet Ultra integration documentation](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md). Model selection, architecture/runtime notes, and compatibility.

[^S3]: [MLX Audio Swift repository](https://github.com/Blaizzy/mlx-audio-swift). Native Swift products and supported model families.

[^S4]: [MLX Audio Swift Qwen recognition/forced-alignment guide](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Qwen3ASR/README.md). Documented checkpoint variants and native integration entry points.

[^S5]: [MLX Qwen3-ASR 1.7B 8-bit checkpoint](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit). Converted checkpoint identity and license metadata.

[^S6]: [FluidAudio v0.17.3 package manifest](https://github.com/FluidInference/FluidAudio/blob/v0.17.3/Package.swift). Declared platform/toolchain and dependencies; inspect alternate toolchain-specific manifests too.

[^S7]: [MLX Audio Swift package manifest](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Package.swift). Checked manifest declares Swift tools 6.2 and macOS 14; resolve transitive requirements during integration.

[^S8]: [Apple — Direct Access to Video Encoding and Decoding, WWDC14](https://developer.apple.com/videos/play/wwdc2014/513/). Core Media rational timing and presentation timestamps.

[^S9]: [Apple AVFoundation Programming Guide — Export / asset reading and writing](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/05_Export.html). Architectural background for audio-track decoding; consult current SDK declarations when implementing.

[^S10]: [FluidAudio v0.17.3 API guide](https://github.com/FluidInference/FluidAudio/blob/v0.17.3/Documentation/API.md). ASR input format, result timing metadata, and model/audio helpers.

[^S11]: [MLX Audio Swift Qwen3-ASR implementation](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift). Checked local-directory loader, sample rate, and chunk/token-budget behavior.

[^S12]: [Official Qwen3-ASR 1.7B model card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B). Recognition language coverage and model-family behavior.

[^S13]: [Official Qwen3-ForcedAligner 0.6B model card](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B). Alignment language coverage and input-duration guidance.

[^S14]: [MLX Audio Swift Qwen3-ForcedAligner implementation](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift). Checked local loading, tokenizer requirements, and alignment result construction.

[^S15]: [MLX Swift installation/build guidance](https://github.com/ml-explore/mlx-swift#installation). Metal resource/build considerations and duplicate-linkage warning.

[^S16]: [FluidInference Parakeet Ultra Core ML checkpoint](https://huggingface.co/FluidInference/parakeet-ultra-coreml). Model component inventory, compatibility, and CC-BY-4.0 metadata.

[^S17]: [MLX Qwen3-ForcedAligner 0.6B 8-bit checkpoint](https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-8bit). Converted checkpoint identity and Apache-2.0 metadata.

[^S18]: [Moondream Parakeet Ultra upstream checkpoint](https://huggingface.co/moondream/parakeet-ultra). Upstream identity, model lineage, and license metadata.

[^S19]: [Apple — Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Reference for the application's existing distribution pipeline.
