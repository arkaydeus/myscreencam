// msc-tool: developer utilities for benchmarking the engine without the app.
//
//   msc-tool import-legacy <legacy Recording_… dir> <output root>
//       Wraps a recording made by the old Electron app as a .mscam (media files are symlinked).
//   msc-tool export <package.mscam> <output file> [--format h264|hevc|prores|gif] [--fps 24|30|60]
//       [--scale 1|0.75|0.5] [--quality low|medium|high|max]
//       Renders + exports with RenderKit/ExportKit and prints wall time and this process's CPU time.
//   msc-tool play <package.mscam> [--seconds N] [--size WxH] [--fps N] [--display-fps N] [--mute] [--meter]
//       Headless editor-playback benchmark: plays the preview composition, pulling frames at display rate.

import AVFoundation
import ExportKit
import Foundation
import ProjectKit
import RenderKit

enum ToolError: Error, CustomStringConvertible {
    case usage(String)
    case sizeMismatch(CGSize, CGSize)

    var description: String {
        switch self {
        case .usage(let message): message
        case .sizeMismatch(let render, let export):
            "Render size \(render) doesn't match the export output size \(export)"
        }
    }
}

func option(_ name: String, in args: [String]) -> String? {
    args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

// MARK: - import-legacy

struct LegacyMeta: Decodable {
    struct Timing: Decodable {
        var screen: Double?
        var webcam: Double?
        var mic: Double?
        var systemAudio: Double?

        enum CodingKeys: String, CodingKey {
            case screen, webcam, mic
            case systemAudio = "system_audio"
        }
    }
    struct Files: Decodable {
        var screen: String
        var systemAudio: String?
        var webcam: String?
        var mic: String?
        var events: String

        enum CodingKeys: String, CodingKey {
            case screen, webcam, mic, events
            case systemAudio = "system_audio"
        }
    }
    var duration: Double?
    var width: Int?
    var height: Int?
    var files: Files
    var timing: Timing?
    var hideSystemCursor: Bool?

    enum CodingKeys: String, CodingKey {
        case duration, width, height, files, timing
        case hideSystemCursor = "hide_system_cursor"
    }
}

struct LegacyEvent: Decodable {
    var type: String
    var t: Double
    var x: Double?
    var y: Double?
    var button: Int?
}

func importLegacy(from legacy: URL, into root: URL) throws -> RecordingPackage {
    let old = try JSONDecoder().decode(LegacyMeta.self, from: Data(contentsOf: legacy.appending(path: "meta.json")))
    let width = old.width ?? 1920
    let height = old.height ?? 1080
    let package = try RecordingPackage.create(in: root)
    let fm = FileManager.default

    var streams: [StreamKind: StreamTiming] = [:]
    let mapping: [(StreamKind, String?, Double?)] = [
        (.screen, old.files.screen, old.timing?.screen),
        (.webcam, old.files.webcam, old.timing?.webcam),
        (.systemAudio, old.files.systemAudio, old.timing?.systemAudio),
        (.microphone, old.files.mic, old.timing?.mic),
    ]
    for (kind, file, offset) in mapping {
        guard let file, fm.fileExists(atPath: legacy.appending(path: file).path) else { continue }
        try fm.createSymbolicLink(at: package.url(for: kind), withDestinationURL: legacy.appending(path: file))
        streams[kind] = StreamTiming(startOffset: offset ?? 0)
    }

    var events: [InputEvent] = []
    let eventsData = (try? Data(contentsOf: legacy.appending(path: old.files.events))) ?? Data()
    for line in eventsData.split(separator: 0x0A) {
        guard let e = try? JSONDecoder().decode(LegacyEvent.self, from: Data(line)), let x = e.x, let y = e.y
        else { continue }
        let kind: InputEvent.Kind? =
            switch e.type {
            case "mouse_move": .move
            case "mouse_down": .down
            case "mouse_up": .up
            default: nil
            }
        guard let kind else { continue }
        events.append(
            InputEvent(t: e.t, kind: kind, x: x / Double(width), y: y / Double(height), button: e.button))
    }
    var eventData = Data()
    for event in events { eventData.append(try InputEventLog.encodeLine(event)) }
    try eventData.write(to: package.url(PackageLayout.events))

    let meta = RecordingMeta(
        name: "Imported \(legacy.lastPathComponent)",
        duration: old.duration ?? 0,
        source: .display(displayID: 0, name: "Legacy import"),
        screen: ScreenStreamInfo(
            pixelWidth: width, pixelHeight: height, scale: 2, frameRate: 60, codec: "avc1",
            contentRectPoints: RectPoints(x: 0, y: 0, width: Double(width) / 2, height: Double(height) / 2)),
        webcam: streams[.webcam] == nil
            ? nil
            : WebcamStreamInfo(deviceID: "legacy", name: "Webcam", pixelWidth: 1280, pixelHeight: 720, frameRate: 30),
        microphone: streams[.microphone] == nil ? nil : AudioDeviceInfo(deviceID: "legacy", name: "Microphone"),
        capturedSystemAudio: streams[.systemAudio] != nil,
        streams: streams,
        systemCursorHidden: old.hideSystemCursor ?? false
    )
    try package.saveMeta(meta)
    try package.saveEdit(EditConfig.makeInitial(meta: meta, events: events, defaults: ProjectDefaults()))
    return package
}

// MARK: - export

func runExport(package: RecordingPackage, to output: URL, args: [String]) async throws {
    let format: ExportFormat =
        switch option("--format", in: args) ?? "h264" {
        case "hevc": .hevc
        case "prores": .proRes422
        case "gif": .gif
        default: .h264
        }
    let fps = ExportFrameRate(rawValue: Int(option("--fps", in: args) ?? "30") ?? 30) ?? .fps30
    let scale = ExportScale(rawValue: Double(option("--scale", in: args) ?? "1") ?? 1) ?? .full
    let quality = ExportQuality(rawValue: option("--quality", in: args) ?? "high") ?? .high
    let settings = ExportSettings(format: format, quality: quality, frameRate: fps, scale: scale)

    let wallStart = Date()
    let cpuStart = cpuSeconds()
    let project = try RenderProject.load(package)
    let natural = try await CompositionBuilder.build(project: project, options: .export(scale: 1, frameRate: 30))
    let expected = settings.outputSize(forSource: natural.renderSize)
    var built = try await CompositionBuilder.build(
        project: project, options: .export(scale: scale.rawValue, frameRate: fps.framesPerSecond))
    if expected != built.renderSize {
        // A preset cap (e.g. GIF's size limit) shrank the output below the plain scale: fit the canvas to it.
        built = try await CompositionBuilder.build(
            project: project,
            options: RenderOptions(
                purpose: .export, frameRate: fps.framesPerSecond,
                sizing: .fit(width: expected.width, height: expected.height)))
    }
    guard expected == built.renderSize else { throw ToolError.sizeMismatch(built.renderSize, expected) }
    print(
        "Rendering \(Int(built.renderSize.width))×\(Int(built.renderSize.height)) @\(fps.framesPerSecond) fps, "
            + "\(String(format: "%.1f", built.duration.seconds)) s, \(project.edit.zoom.keyframes.count) zooms")

    // --raw: skip the custom compositor (measures decode + encode only).
    let raw = args.contains("--raw")
    let job = VideoExporter().start(
        asset: built.composition, videoComposition: raw ? nil : built.videoComposition, audioMix: built.audioMix,
        to: output, settings: settings)
    let result = try await job.result
    let wall = Date().timeIntervalSince(wallStart)
    let cpu = cpuSeconds() - cpuStart
    print(
        String(
            format: "export wall: %.2f s, process CPU: %.2f s, encoder: %@, size: %.1f MB, frames: %d → %@",
            wall, cpu, result.encoder.rawValue, Double(result.fileSize) / 1_048_576, result.frameCount,
            result.url.path))
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "import-legacy" where args.count >= 3:
        let package = try importLegacy(
            from: URL(filePath: args[1], directoryHint: .isDirectory),
            into: URL(filePath: args[2], directoryHint: .isDirectory))
        print(package.url.path)
    case "export" where args.count >= 3:
        try await runExport(
            package: RecordingPackage(url: URL(filePath: args[1], directoryHint: .isDirectory)),
            to: URL(filePath: args[2]), args: args)
    case "play" where args.count >= 2:
        try await runPlay(
            package: RecordingPackage(url: URL(filePath: args[1], directoryHint: .isDirectory)), args: args)
    default:
        throw ToolError.usage(
            "usage: msc-tool import-legacy <legacy dir> <root> | export <pkg> <out> [options] | play <pkg> [options]")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
