// swift-tools-version: 6.0

import PackageDescription

// Engine modules for MyScreenArt. The app target in `project.yml` links these products.
//
// Layering (a module may only depend on modules above it):
//   MyScreenArtCore  – paths, logging, clock helpers
//   CaptureKit       – ScreenCaptureKit / AVCapture / event tap        (phase 1)
//   ProjectKit       – package model, library, thumbnails, waveforms   (phase 2)
//   RecordingKit     – recording session + writers                     (phase 1)
//   RenderKit        – timeline math, composition, compositor          (phase 3)
//   ExportKit        – reader/writer export pipeline                   (phase 5)
// Modules are added when their phase starts.

let package = Package(
    name: "MyScreenArtKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MyScreenArtCore", targets: ["MyScreenArtCore"])
    ],
    targets: [
        .target(name: "MyScreenArtCore"),
        .testTarget(name: "MyScreenArtCoreTests", dependencies: ["MyScreenArtCore"]),
    ]
)
