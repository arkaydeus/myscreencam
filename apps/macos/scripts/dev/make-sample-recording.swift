#!/usr/bin/env swift  // Writes a realistic synthetic MyScreenArt recording package (`.msarec`) for development and integration tests.
//
// Usage (full Xcode is needed for AVFoundation's encoders; mise sets DEVELOPER_DIR):
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/dev/make-sample-recording.swift <folder>
//     [--duration 20] [--name "Sample Recording"] [--codec hevc|h264]
//     [--no-webcam] [--no-system-audio] [--no-mic] [--cursor-visible]
//
// Creates `<folder>/Recording_YYYYMMDD_HHMMSS_xxxxxxxx.msarec` and prints its path on stdout. Contents:
// - `screen.mov`   1920×1080 @30 (HEVC by default): moving shapes, a scrolling "document", a running clock and a
//                  frame counter, so cuts, zooms and sync are easy to see.
// - `webcam.mov`   1280×720 @30, H.264, starting 0.4 s into the session (a stream start offset), ends early.
// - `sysaudio.m4a` 48 kHz AAC: a 440 Hz tone whose loudness swells and fades (waveforms look like music).
// - `mic.m4a`      48 kHz AAC: 180–260 Hz "speech" bursts, starting 0.25 s into the session.
// - `events.jsonl` pointer moves along a smooth path, drags and a few left clicks, with cursor image ids.
// - `cursors/`     `index.json` + PNGs of the arrow and pointing-hand cursors.
// - `meta.json`    matching ProjectKit's `RecordingMeta` Codable shape, with one pause record.
// No `edit.json`: the editor creates it (with auto-zooms from the clicks) on first open.
//
// Only Apple frameworks are used, and the JSON is written by hand (mirroring ProjectKit's encoders), so the script
// runs without building the SwiftPM package.

import AVFoundation
import AppKit
import CoreText
import Foundation

// MARK: - Arguments

struct Options {
    var folder: URL
    var duration = 20.0
    var name = "Sample Recording"
    var codec = AVVideoCodecType.hevc
    var webcam = true
    var systemAudio = true
    var microphone = true
    var cursorHidden = true
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    func usage() -> Never {
        FileHandle.standardError.write(
            Data(
                ("usage: make-sample-recording.swift <folder> [--duration s] [--name n] [--codec hevc|h264] "
                    + "[--no-webcam] [--no-system-audio] [--no-mic] [--cursor-visible]\n").utf8))
        exit(2)
    }
    guard let first = args.first, !first.hasPrefix("-") else { usage() }
    args.removeFirst()
    var options = Options(folder: URL(fileURLWithPath: (first as NSString).expandingTildeInPath))
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--duration":
            guard let v = args.first.flatMap(Double.init), v >= 2 else { usage() }
            args.removeFirst()
            options.duration = v
        case "--name":
            guard let v = args.first else { usage() }
            args.removeFirst()
            options.name = v
        case "--codec":
            guard let v = args.first else { usage() }
            args.removeFirst()
            switch v {
            case "hevc": options.codec = .hevc
            case "h264": options.codec = .h264
            default: usage()
            }
        case "--no-webcam": options.webcam = false
        case "--no-system-audio": options.systemAudio = false
        case "--no-mic": options.microphone = false
        case "--cursor-visible": options.cursorHidden = false
        default: usage()
        }
    }
    return options
}

// MARK: - Constants

let screenSize = (w: 1920, h: 1080)
let webcamSize = (w: 1280, h: 720)
let fps = 30
let webcamOffset = 0.4
let micOffset = 0.25

// MARK: - Pointer path (normalised, y down)

/// A smooth Lissajous-like path the "user" moves the pointer along.
func pointer(at t: Double) -> (x: Double, y: Double) {
    let x = 0.5 + 0.32 * sin(t * 0.61) + 0.06 * sin(t * 2.3)
    let y = 0.5 + 0.28 * sin(t * 0.43 + 1.1) + 0.05 * cos(t * 1.7)
    return (min(max(x, 0.02), 0.98), min(max(y, 0.02), 0.98))
}

/// Left clicks (session seconds), spread over the recording.
func clickTimes(duration: Double) -> [Double] {
    let fractions = [0.08, 0.2, 0.34, 0.47, 0.62, 0.76, 0.9]
    return fractions.map { ($0 * duration * 100).rounded() / 100 }
}

// MARK: - Drawing helpers

func makeContext(for buffer: CVPixelBuffer) -> CGContext? {
    CVPixelBufferLockBaseAddress(buffer, [])
    return CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
        height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
}

func drawText(
    _ string: String, in ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor,
    weight: NSFont.Weight = .regular, monospaced: Bool = false
) {
    let font =
        monospaced
        ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(
        string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.saveGState()
    // The context is y-up; `y` is measured from the top (y down) like everything else here.
    ctx.textPosition = CGPoint(x: x, y: CGFloat(ctx.height) - y - size)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Draws one screen frame (y-down coordinates via a flipped CTM for shapes).
func drawScreen(_ ctx: CGContext, t: Double, frame: Int, duration: Double) {
    let w = CGFloat(screenSize.w)
    let h = CGFloat(screenSize.h)
    // Background: slowly shifting gradient.
    let hue = CGFloat((t / duration) * 0.35)
    let top = NSColor(hue: 0.58 + hue * 0.3, saturation: 0.35, brightness: 0.22, alpha: 1).cgColor
    let bottom = NSColor(hue: 0.68 + hue * 0.3, saturation: 0.45, brightness: 0.12, alpha: 1).cgColor
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

    ctx.saveGState()
    ctx.translateBy(x: 0, y: h)
    ctx.scaleBy(x: 1, y: -1)  // y down from here on

    // Menu bar and a window.
    ctx.setFillColor(rgb(0.1, 0.1, 0.12, 0.9))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: 30))
    let window = CGRect(x: 160, y: 110, width: 1180, height: 820)
    ctx.setFillColor(rgb(0.97, 0.97, 0.98))
    ctx.addPath(CGPath(roundedRect: window, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(rgb(0.9, 0.9, 0.92))
    ctx.fill(CGRect(x: window.minX, y: window.minY + 14, width: window.width, height: 30))
    ctx.fill(CGRect(x: window.minX + 14, y: window.minY, width: window.width - 28, height: 20))
    for (i, color) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.8, 0.26)].enumerated() {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: window.minX + 18 + CGFloat(i) * 22, y: window.minY + 14, width: 13, height: 13))
    }

    // Scrolling "document" lines inside the window.
    ctx.saveGState()
    ctx.clip(to: window.insetBy(dx: 24, dy: 60).offsetBy(dx: 0, dy: 30))
    let scroll = CGFloat(t * 38).truncatingRemainder(dividingBy: 44)
    for row in 0..<22 {
        let y = window.minY + 80 + CGFloat(row) * 44 - scroll
        let widthFactor = 0.45 + 0.5 * abs(sin(Double(row + Int(t * 38 / 44)) * 1.7))
        ctx.setFillColor(row % 5 == 0 ? rgb(0.2, 0.35, 0.8) : rgb(0.72, 0.74, 0.78))
        ctx.fill(
            CGRect(x: window.minX + 48, y: y, width: (window.width - 96) * widthFactor, height: row % 5 == 0 ? 18 : 12))
    }
    ctx.restoreGState()

    // A sidebar with a bouncing coloured card.
    let side = CGRect(x: 1400, y: 110, width: 360, height: 820)
    ctx.setFillColor(rgb(0.16, 0.17, 0.2, 0.92))
    ctx.addPath(CGPath(roundedRect: side, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
    let bounce = CGFloat(abs(sin(t * 1.3))) * 520
    ctx.setFillColor(
        NSColor(
            hue: CGFloat(t * 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.7,
            brightness: 0.95, alpha: 1
        ).cgColor)
    ctx.addPath(
        CGPath(
            roundedRect: CGRect(x: side.minX + 40, y: side.minY + 200 + bounce, width: 280, height: 120),
            cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.fillPath()

    // An orbiting marker (good for checking zoom targets and blur).
    let orbit = CGPoint(x: 750 + 300 * cos(t * 0.9), y: 520 + 200 * sin(t * 0.9))
    ctx.setFillColor(rgb(0.95, 0.3, 0.2))
    ctx.fillEllipse(in: CGRect(x: orbit.x - 36, y: orbit.y - 36, width: 72, height: 72))
    ctx.restoreGState()

    // Text (drawn in the y-up context with a y-down position).
    let white = rgb(1, 1, 1)
    let seconds = Int(t)
    let clock = String(format: "%02d:%02d.%02d", seconds / 60, seconds % 60, Int((t - Double(seconds)) * 100))
    drawText(clock, in: ctx, x: 1420, y: 150, size: 64, color: white, weight: .semibold, monospaced: true)
    drawText("frame \(frame)", in: ctx, x: 1420, y: 236, size: 28, color: rgb(0.8, 0.85, 0.95), monospaced: true)
    drawText("MyScreenArt sample recording", in: ctx, x: 20, y: 5, size: 18, color: white, weight: .medium)
    drawText(
        "Second \(seconds)", in: ctx, x: window.minX + 48, y: window.minY + 36, size: 22,
        color: rgb(0.1, 0.1, 0.12), weight: .bold)
}

func drawWebcam(_ ctx: CGContext, t: Double, frame: Int) {
    let w = CGFloat(webcamSize.w)
    let h = CGFloat(webcamSize.h)
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [rgb(0.36, 0.3, 0.26), rgb(0.16, 0.13, 0.12)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(
        gradient, startCenter: CGPoint(x: w * 0.5, y: h * 0.6), startRadius: 0,
        endCenter: CGPoint(x: w * 0.5, y: h * 0.6), endRadius: w * 0.7, options: .drawsAfterEndLocation)
    // A "head" that sways.
    let sway = CGFloat(sin(t * 1.4)) * 40
    ctx.setFillColor(rgb(0.93, 0.76, 0.62))
    ctx.fillEllipse(in: CGRect(x: w / 2 - 150 + sway, y: h * 0.28, width: 300, height: 360))
    ctx.setFillColor(rgb(0.2, 0.35, 0.65))
    ctx.fillEllipse(in: CGRect(x: w / 2 - 330 + sway * 0.5, y: -260, width: 660, height: 420))
    // Blinking eyes.
    let blink = frame % 90 < 4
    ctx.setFillColor(rgb(0.1, 0.1, 0.1))
    for dx in [-60.0, 60.0] {
        ctx.fillEllipse(
            in: CGRect(x: w / 2 + CGFloat(dx) - 14 + sway, y: h * 0.28 + 220, width: 28, height: blink ? 4 : 28))
    }
    drawText(
        String(format: "cam %.2f", t + webcamOffset), in: ctx, x: 30, y: 24, size: 40, color: rgb(1, 1, 1),
        weight: .semibold, monospaced: true)
}

// MARK: - Writers

func writeVideo(
    to url: URL, width: Int, height: Int, frames: Int, codec: AVVideoCodecType,
    draw: @escaping (CGContext, Int) -> Void
) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer, let ctx = makeContext(for: buffer) else { throw CocoaError(.fileWriteUnknown) }
        draw(ctx, frame)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

/// Writes 48 kHz mono AAC from a sample function.
func writeAudio(to url: URL, seconds: Double, sample: (Double) -> Float) throws {
    try? FileManager.default.removeItem(at: url)
    let rate = 48_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let total = Int(rate * seconds)
    let chunk = 4800
    var written = 0
    while written < total {
        let n = min(chunk, total - written)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let samples = buffer.floatChannelData![0]
        for i in 0..<n { samples[i] = sample(Double(written + i) / rate) }
        try file.write(from: buffer)
        written += n
    }
    file.close()
}

/// Writes the cursor's 2× bitmap (or its largest one) as a PNG; returns the pixel size.
func writePNG(_ image: NSImage, to url: URL) throws -> (pixelsWide: Int, pixelsHigh: Int) {
    let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
    let target = Int(image.size.width * 2)
    guard let rep = reps.first(where: { $0.pixelsWide == target }) ?? reps.max(by: { $0.pixelsWide < $1.pixelsWide }),
        let data = rep.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
    return (rep.pixelsWide, rep.pixelsHigh)
}

// MARK: - JSON (mirrors ProjectKit's Codable output)

/// A tiny JSON writer (sorted keys) that prints numbers in Swift's shortest form (`0.4`, not
/// `0.40000000000000002`), like `JSONEncoder`. Supports the value types used here.
func json(_ value: Any, pretty: Bool = true, indent: String = "") -> String {
    let inner = indent + "  "
    let open = pretty ? "\n" + inner : ""
    let separator = pretty ? ",\n" + inner : ","
    let close = pretty ? "\n" + indent : ""
    let colon = pretty ? " : " : ":"
    switch value {
    case let v as Bool: return v ? "true" : "false"
    case let v as Int: return String(v)
    case let v as Double:
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        return String(v)
    case let v as CGFloat: return json(Double(v), pretty: pretty, indent: indent)
    case let v as String:
        var out = "\""
        for scalar in v.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    case let v as [Any]:
        if v.isEmpty { return "[]" }
        return "[" + open + v.map { json($0, pretty: pretty, indent: inner) }.joined(separator: separator) + close + "]"
    case let v as [String: Any]:
        if v.isEmpty { return "{}" }
        let items = v.keys.sorted().map { json($0) + colon + json(v[$0]!, pretty: pretty, indent: inner) }
        return "{" + open + items.joined(separator: separator) + close + "}"
    default:
        fatalError("Unsupported JSON value \(value)")
    }
}

func jsonData(_ object: Any) -> Data { Data((json(object) + "\n").utf8) }

func jsonLine(_ object: [String: Any]) -> String { json(object, pretty: false) }

func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

// MARK: - Main

let options = parseOptions()
// Cursor images are only available once the application object exists.
_ = NSApplication.shared
let fm = FileManager.default
try fm.createDirectory(at: options.folder, withIntermediateDirectories: true)

let createdAt = Date()
let id = UUID()
let stamp: String = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    return formatter.string(from: createdAt)
}()
let suffix = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
let package = options.folder.appending(path: "Recording_\(stamp)_\(suffix).msarec", directoryHint: .isDirectory)
try fm.createDirectory(at: package.appending(path: "cursors"), withIntermediateDirectories: true)
try fm.createDirectory(at: package.appending(path: "cache"), withIntermediateDirectories: true)

let duration = options.duration
let screenFrames = Int(duration * Double(fps))
let webcamSeconds = max(1, duration - webcamOffset - 0.3)

FileHandle.standardError.write(Data("Writing \(package.lastPathComponent)…\n".utf8))

try await writeVideo(
    to: package.appending(path: "screen.mov"), width: screenSize.w, height: screenSize.h, frames: screenFrames,
    codec: options.codec
) { ctx, frame in
    drawScreen(ctx, t: Double(frame) / Double(fps), frame: frame, duration: duration)
}

if options.webcam {
    try await writeVideo(
        to: package.appending(path: "webcam.mov"), width: webcamSize.w, height: webcamSize.h,
        frames: Int(webcamSeconds * Double(fps)), codec: .h264
    ) { ctx, frame in
        drawWebcam(ctx, t: Double(frame) / Double(fps), frame: frame)
    }
}

if options.systemAudio {
    try writeAudio(to: package.appending(path: "sysaudio.m4a"), seconds: duration) { t in
        let envelope = 0.25 + 0.2 * sin(t * 0.8) + 0.12 * sin(t * 3.1)
        let beat = t.truncatingRemainder(dividingBy: 0.5) < 0.06 ? 0.25 : 0
        return Float(max(0, envelope + beat) * sin(2 * .pi * 440 * t) + 0.05 * sin(2 * .pi * 660 * t))
    }
}

if options.microphone {
    try writeAudio(to: package.appending(path: "mic.m4a"), seconds: duration - micOffset) { t in
        // Syllable-like bursts: on for ~0.3 s, off for ~0.15 s, with pauses every few seconds.
        let phrase = t.truncatingRemainder(dividingBy: 4.2) < 3.0
        let syllable = sin(.pi * (t.truncatingRemainder(dividingBy: 0.45)) / 0.3)
        guard phrase, t.truncatingRemainder(dividingBy: 0.45) < 0.3 else { return 0 }
        let pitch = 180 + 80 * sin(t * 1.9)
        return Float(0.55 * syllable * sin(2 * .pi * pitch * t) + 0.1 * syllable * sin(2 * .pi * pitch * 2.03 * t))
    }
}

// Cursor images.
let cursorImages: [(id: Int, cursor: NSCursor, kind: String)] = [
    (0, .arrow, "arrow"), (1, .pointingHand, "pointingHand"),
]
var cursorJSON: [[String: Any]] = []
for entry in cursorImages {
    let file = "cursors/\(entry.id).png"
    let pixels = try writePNG(entry.cursor.image, to: package.appending(path: file))
    let size = entry.cursor.image.size
    cursorJSON.append([
        "id": entry.id, "file": file, "width": Double(size.width), "height": Double(size.height),
        "scale": size.width > 0 ? Double(pixels.pixelsWide) / Double(size.width) : 1.0,
        "hotspotX": Double(entry.cursor.hotSpot.x), "hotspotY": Double(entry.cursor.hotSpot.y), "kind": entry.kind,
    ])
}
try jsonData(["cursors": cursorJSON]).write(to: package.appending(path: "cursors/index.json"))

// Events: moves every 1/60 s (drags while the left button is held), left clicks as down/up pairs, one drag, one
// scroll and one right click. Written in time order.
var events: [[String: Any]] = []
func event(_ t: Double, _ kind: String, _ p: (x: Double, y: Double), button: Int? = nil) -> [String: Any] {
    var e: [String: Any] = ["t": round3(t), "k": kind, "x": round3(p.x), "y": round3(p.y)]
    // The pointing hand shows over the sidebar (right part of the screen).
    e["c"] = p.x > 0.72 ? 1 : 0
    if let button { e["b"] = button }
    return e
}
let dragStart = round3(duration * 0.55)
let dragEnd = round3(dragStart + 1.2)
var t = 0.3
while t < duration - 0.05 {
    let dragging = t > dragStart && t < dragEnd
    events.append(event(t, "move", pointer(at: t), button: dragging ? 0 : nil))
    t += 1.0 / 60
}
for click in clickTimes(duration: duration) {
    events.append(event(click, "down", pointer(at: click), button: 0))
    events.append(event(click + 0.09, "up", pointer(at: click), button: 0))
}
events.append(event(dragStart, "down", pointer(at: dragStart), button: 0))
events.append(event(dragEnd, "up", pointer(at: dragEnd), button: 0))
var scroll = event(duration * 0.3, "scroll", pointer(at: duration * 0.3))
scroll["dx"] = 0
scroll["dy"] = -12.5
events.append(scroll)
events.append(event(duration * 0.7, "down", pointer(at: duration * 0.7), button: 1))
events.append(event(duration * 0.7 + 0.08, "up", pointer(at: duration * 0.7), button: 1))
let sortedEvents = events.enumerated().sorted {
    let a = $0.element["t"] as! Double
    let b = $1.element["t"] as! Double
    return a == b ? $0.offset < $1.offset : a < b
}
let eventLines = sortedEvents.map { jsonLine($0.element) + "\n" }.joined()
try eventLines.write(to: package.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)

// meta.json
let isoFormatter = ISO8601DateFormatter()
isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
var streams: [String: Any] = ["screen": ["startOffset": 0.0]]
if options.webcam { streams["webcam"] = ["startOffset": webcamOffset] }
if options.systemAudio { streams["systemAudio"] = ["startOffset": 0.0] }
if options.microphone { streams["microphone"] = ["startOffset": micOffset] }
var meta: [String: Any] = [
    "version": 1,
    "id": id.uuidString,
    "name": options.name,
    "createdAt": isoFormatter.string(from: createdAt),
    "duration": duration,
    "source": ["display": ["displayID": 1, "name": "Built-in Retina Display"]],
    "screen": [
        "pixelWidth": screenSize.w, "pixelHeight": screenSize.h, "scale": 2.0, "frameRate": fps,
        "codec": options.codec == .hevc ? "hvc1" : "avc1",
        "contentRectPoints": ["x": 0.0, "y": 0.0, "width": 960.0, "height": 540.0],
    ],
    "capturedSystemAudio": options.systemAudio,
    "streams": streams,
    "pauses": [["at": round3(duration * 0.6), "skipped": 3.25]],
    "systemCursorHidden": options.cursorHidden,
    "appVersion": "sample-script",
]
if options.webcam {
    meta["webcam"] = [
        "deviceID": "sample-camera", "name": "Sample Camera", "pixelWidth": webcamSize.w,
        "pixelHeight": webcamSize.h, "frameRate": fps,
    ]
}
if options.microphone { meta["microphone"] = ["deviceID": "sample-mic", "name": "Sample Microphone"] }
try jsonData(meta).write(to: package.appending(path: "meta.json"), options: .atomic)

print(package.path)
