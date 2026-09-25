// swift-tools-version: 6.0

import PackageDescription

// Engine modules for MyScreenArt. The app target in `project.yml` links these products.
//
// Layering (a module may only depend on modules above it):
//   MyScreenArtCore  – paths, logging, clock helpers
//   ProjectKit       – package format + edit model (the shared contract), library, thumbnails, waveforms, presets
//   CaptureKit       – ScreenCaptureKit / AVCapture / event tap / cursor capture / permissions
//   RecordingKit     – recording session, writers, package writer
//   RenderKit        – timeline math, effect math, composition builder, Core Image compositor, audio mix
//   ExportKit        – reader/writer export pipeline, presets, GIF

let package = Package(
    name: "MyScreenArtKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MyScreenArtCore", targets: ["MyScreenArtCore"]),
        .library(name: "ProjectKit", targets: ["ProjectKit"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "RecordingKit", targets: ["RecordingKit"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
        .library(name: "ExportKit", targets: ["ExportKit"]),
    ],
    targets: [
        .target(name: "MyScreenArtCore"),
        .target(name: "ProjectKit", dependencies: ["MyScreenArtCore"]),
        .target(name: "CaptureKit", dependencies: ["MyScreenArtCore", "ProjectKit"]),
        .target(name: "RecordingKit", dependencies: ["MyScreenArtCore", "ProjectKit", "CaptureKit"]),
        .target(
            name: "RenderKit",
            dependencies: ["MyScreenArtCore", "ProjectKit"],
            resources: [.process("Resources")]
        ),
        .target(name: "ExportKit", dependencies: ["MyScreenArtCore"]),

        .testTarget(name: "MyScreenArtCoreTests", dependencies: ["MyScreenArtCore"]),
        .testTarget(name: "ProjectKitTests", dependencies: ["ProjectKit"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        .testTarget(name: "RecordingKitTests", dependencies: ["RecordingKit"]),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit"]),
        .testTarget(name: "ExportKitTests", dependencies: ["ExportKit"]),
    ]
)
