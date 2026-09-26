// RenderKit: the one renderer behind the editor preview (AVPlayer) and export (AVAssetReader).
//
// - Math/          pure effect math: easing, zoom, cursor track, follow camera, layouts, preview hit-testing.
// - Composition/   RenderProject/RenderOptions, CompositionBuilder (AVComposition + video composition + audio mix),
//                  ProjectRenderer (editor-facing, cheap incremental updates).
// - Compositor/    VideoCompositor (custom AVVideoCompositing), FrameRenderer (Core Image recipe per frame),
//                  RenderSnapshot (immutable per-edit render state), cursor artwork, background.
// - Audio/         MTAudioProcessingTap gain/limiter/metering, AudioLevels, MeterBallistics.
