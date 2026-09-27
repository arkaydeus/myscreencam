// swift-tools-version: 6.0

import PackageDescription

// Engine modules for My Screen Cam. The app target in `project.yml` links these products.
//
// Layering (a module may only depend on modules above it):
//   MyScreenCamCore  – paths, logging, clock helpers
//   ProjectKit       – package format + edit model (the shared contract), library, thumbnails, waveforms, presets
//   CaptureKit       – ScreenCaptureKit / AVCapture / event tap / cursor capture / permissions
//   RecordingKit     – recording session, writers, package writer
//   RenderKit        – timeline math, effect math, composition builder, Core Image compositor, audio mix
//   ExportKit        – reader/writer export pipeline, presets, GIF
//   SpeechCore       – speech-model catalogue/downloads, audio preparation, worker protocol, transcript assembly
//                      (no SDKs: the recognisers live in Packages/SpeechEngines, linked only by the XPC service)

let package = Package(
    name: "MyScreenCamKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MyScreenCamCore", targets: ["MyScreenCamCore"]),
        .library(name: "ProjectKit", targets: ["ProjectKit"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "RecordingKit", targets: ["RecordingKit"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
        .library(name: "ExportKit", targets: ["ExportKit"]),
        .library(name: "SpeechCore", targets: ["SpeechCore"]),
    ],
    targets: [
        .target(name: "MyScreenCamCore"),
        .target(name: "ProjectKit", dependencies: ["MyScreenCamCore"]),
        .target(name: "CaptureKit", dependencies: ["MyScreenCamCore", "ProjectKit"]),
        .target(name: "RecordingKit", dependencies: ["MyScreenCamCore", "ProjectKit", "CaptureKit"]),
        .target(
            name: "RenderKit",
            dependencies: ["MyScreenCamCore", "ProjectKit"],
            resources: [.process("Resources")]
        ),
        .target(name: "ExportKit", dependencies: ["MyScreenCamCore"]),
        .target(
            name: "SpeechCore",
            dependencies: ["MyScreenCamCore", "ProjectKit"],
            resources: [.copy("Resources/catalogue.json")]
        ),
        // Developer tool (import legacy recordings, export benchmark); not shipped in the app.
        .executableTarget(name: "msc-tool", dependencies: ["ProjectKit", "RenderKit", "ExportKit"]),

        .testTarget(name: "MyScreenCamCoreTests", dependencies: ["MyScreenCamCore"]),
        .testTarget(name: "ProjectKitTests", dependencies: ["ProjectKit"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        .testTarget(name: "RecordingKitTests", dependencies: ["RecordingKit"]),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit"]),
        .testTarget(name: "ExportKitTests", dependencies: ["ExportKit"]),
        .testTarget(name: "SpeechCoreTests", dependencies: ["SpeechCore", "ProjectKit"]),
    ]
)
