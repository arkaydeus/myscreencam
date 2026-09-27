// swift-tools-version: 6.2

import PackageDescription

// Speech recognition backends for My Screen Cam. Only the `MyScreenCamSpeech` XPC service (and the developer
// `speech-tool`) link this package, so the app, the Quick Look extension and `MyScreenCamKit`'s tests never compile
// MLX or Core ML model code. See docs/subtitles-plan.md and docs/speech-integration.md.
//
// Pins: FluidAudio exactly 0.17.3 (Parakeet Ultra support), without its NeMo text-normalisation binary (we keep
// the recogniser's raw text). mlx-audio-swift at a reviewed commit; only its STT/Core products are used. The MLX and
// tokenizer packages it pulls in are pinned exactly here too, because the app's Xcode build resolves the graph itself
// (its resolution isn't committed) and must get the same runtime as `Package.resolved` and the measurements in
// docs/speech-integration.md. Build with xcodebuild (MLX's Metal shaders don't build under `swift build`).

let package = Package(
    name: "SpeechEngines",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SpeechEngines", targets: ["SpeechEngines"]),
        .executable(name: "speech-tool", targets: ["speech-tool"]),
    ],
    dependencies: [
        .package(path: "../MyScreenCamKit"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.3", traits: []),
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.11.0"),
    ],
    targets: [
        .target(
            name: "SpeechEngines",
            dependencies: [
                .product(name: "SpeechCore", package: "MyScreenCamKit"),
                .product(name: "ProjectKit", package: "MyScreenCamKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                // Linked through MLXAudioSTT anyway; listed so the exact pins above apply.
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ]
        ),
        .executableTarget(
            name: "speech-tool",
            dependencies: [
                "SpeechEngines",
                .product(name: "SpeechCore", package: "MyScreenCamKit"),
                .product(name: "ProjectKit", package: "MyScreenCamKit"),
            ]
        ),
        .testTarget(
            name: "SpeechEnginesTests",
            dependencies: [
                "SpeechEngines",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SpeechCore", package: "MyScreenCamKit"),
                .product(name: "ProjectKit", package: "MyScreenCamKit"),
            ]
        ),
    ]
)
