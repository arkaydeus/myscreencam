import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import MyScreenArtCore
import Synchronization

/// The one Metal-backed `CIContext` used for every frame (preview and export).
///
/// Colour: sources are decoded through their own colour tags (untagged video is treated as BT.709), composited in
/// a gamma-encoded sRGB working space (so shadows and anti-aliasing blend like CSS), and written as BT.709.
/// sRGB and BT.709 share primaries, so untouched pixels round-trip unchanged.
public enum RenderContext {
    /// The shared GPU context. Thread-safe.
    public static let shared: CIContext = {
        var options: [CIContextOption: Any] = [
            .workingColorSpace: CIHelpers.sRGB,
            .cacheIntermediates: false,
            .name: "RenderKit",
        ]
        options[.outputPremultiplied] = true
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// Colour space frames are written in: the space Core Video derives from the BT.709 attachments stamped on
    /// every output buffer. Using exactly that space (rather than `CGColorSpace.itur_709`, whose transfer curve
    /// differs) makes a BT.709-tagged source round-trip bit-for-bit through the compositor.
    public static let outputColorSpace: CGColorSpace = {
        CVImageBufferCreateColorSpaceFromAttachments(outputAttachments as CFDictionary)?.takeRetainedValue()
            ?? CIHelpers.itur709
    }()

    /// BT.709 attachments stamped on every composed frame.
    static var outputAttachments: [CFString: CFString] {
        [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
    }

    /// Wraps a decoded frame without copying. Untagged buffers are interpreted as BT.709.
    static func image(from buffer: CVPixelBuffer) -> CIImage {
        let tagged = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) != nil
        if tagged { return CIImage(cvPixelBuffer: buffer) }
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: outputColorSpace])
    }

    /// Renders `image` into `buffer` (BGRA or 420v, IOSurface-backed) on the GPU and waits for completion.
    static func render(_ image: CIImage, into buffer: CVPixelBuffer) throws {
        _ = try startRender(image, into: buffer).waitUntilCompleted()
    }

    /// Submits the GPU work to render `image` into `buffer` and returns without waiting.
    static func startRender(_ image: CIImage, into buffer: CVPixelBuffer) throws -> CIRenderTask {
        for (key, value) in outputAttachments {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = outputColorSpace
        destination.alphaMode = .none
        return try shared.startTask(toRender: image, to: destination)
    }
}

/// Pixel formats the compositor reads and writes.
enum CompositorPixelFormats {
    static let yuv420v = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    static let yuv420f = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    static let bgra = kCVPixelFormatType_32BGRA
    static let yuv10 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    static let source: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [yuv420v, yuv420f, bgra, yuv10],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    /// 420v first (what export asks for and the cheapest to display), then BGRA.
    static let output: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [yuv420v, bgra],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
}

/// A video composition instruction carrying an immutable render snapshot.
/// `@unchecked Sendable`: every stored property is immutable (`[NSValue]` just isn't marked Sendable).
final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// Frames change even when the sources don't (cursor, zoom), so AVFoundation must never reuse a frame.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let snapshot: RenderSnapshot

    init(timeRange: CMTimeRange, snapshot: RenderSnapshot) {
        self.timeRange = timeRange
        self.snapshot = snapshot
        requiredSourceTrackIDs = snapshot.trackIDs.videoTrackIDs.map { NSNumber(value: $0) }
    }
}

/// The custom `AVVideoCompositing` used for both `AVPlayer` preview and `AVAssetReader` export.
///
/// AVFoundation creates it by class and calls it on its own queues. It holds no edit state: every request's
/// instruction carries the `RenderSnapshot` to draw with, so swapping a video composition is race-free.
public final class VideoCompositor: NSObject, AVVideoCompositing, Sendable {
    /// Builds each frame's Core Image graph and submits it to the GPU, one request at a time.
    private let queue = DispatchQueue(label: "com.myscreenart.renderkit.compositor", qos: .userInteractive)
    /// Waits for submitted GPU work and finishes requests, so building frame N+1 overlaps rendering frame N.
    private let completionQueue = DispatchQueue(
        label: "com.myscreenart.renderkit.compositor.completion", qos: .userInteractive, attributes: .concurrent)
    /// Bounds frames in flight on the GPU. Each holds its decoded source frames (7–30 MB at Retina sizes), so an
    /// unbounded pipeline lets memory grow whenever the GPU is slower than decoding.
    private let inFlight = DispatchSemaphore(value: 3)
    private let generation = Atomic<Int>(0)

    override public init() {
        super.init()
    }

    public var sourcePixelBufferAttributes: [String: any Sendable]? { CompositorPixelFormats.source }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        CompositorPixelFormats.output
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Nothing is cached per render context: each request reads its size from the output buffer.
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let started = generation.load(ordering: .acquiring)
        queue.async { [self] in
            if generation.load(ordering: .acquiring) != started {
                request.finishCancelledRequest()
                return
            }
            let state = Log.signposter.beginInterval("composite")
            inFlight.wait()
            do {
                let (output, task) = try compose(request)
                let pending = PendingRender(task: task, output: output)
                completionQueue.async { [inFlight] in
                    defer {
                        inFlight.signal()
                        Log.signposter.endInterval("composite", state)
                    }
                    do {
                        _ = try pending.task.waitUntilCompleted()
                        request.finish(withComposedVideoFrame: pending.output)
                    } catch {
                        request.finish(with: error)
                    }
                }
            } catch {
                inFlight.signal()
                Log.signposter.endInterval("composite", state)
                request.finish(with: error)
            }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        generation.add(1, ordering: .releasing)
    }

    /// Builds the frame and submits it to the GPU; the caller waits on the returned task.
    private func compose(_ request: AVAsynchronousVideoCompositionRequest) throws -> (CVPixelBuffer, CIRenderTask) {
        guard let instruction = request.videoCompositionInstruction as? RenderInstruction else {
            throw RenderError.unexpectedInstruction
        }
        guard let output = request.renderContext.newPixelBuffer() else { throw RenderError.noOutputBuffer }
        let snapshot = instruction.snapshot
        let ids = snapshot.trackIDs
        let screen = request.sourceFrame(byTrackID: ids.screen).map(RenderContext.image(from:))
        let webcam = ids.webcam.flatMap { request.sourceFrame(byTrackID: $0) }.map(RenderContext.image(from:))
        let editedTime = request.compositionTime.seconds
        let sourceTime = snapshot.sourceTime(forEdited: editedTime.isFinite ? editedTime : 0)
        let size = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
        let image = FrameRenderer.compose(
            screen: screen, webcam: webcam, snapshot: snapshot, sourceTime: sourceTime, canvasSize: size,
            highQuality: true)
        return (output, try RenderContext.startRender(image, into: output))
    }
}

/// `CIRenderTask` and `CVPixelBuffer` aren't marked Sendable; the pair is handed to the completion queue once
/// and never touched again by the submitting queue.
private struct PendingRender: @unchecked Sendable {
    let task: CIRenderTask
    let output: CVPixelBuffer
}

/// Errors from building or rendering a composition.
public enum RenderError: Error, Equatable {
    case missingScreenTrack
    case emptyTimeline
    case unexpectedInstruction
    case noOutputBuffer
}
