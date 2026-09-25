import AVFoundation
import CoreImage
import Synchronization

/// A Core Image custom compositor, shaped like RenderKit's: it renders the first source frame (scaled
/// to the render size) into the destination buffer, whatever pixel format ExportKit asked for.
final class CoreImageTestCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// Destination pixel formats seen, so tests can check the contract.
    static let seenFormats = Mutex<Set<OSType>>([])

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let trackID = request.sourceTrackIDs.first?.int32Value,
            let source = request.sourceFrame(byTrackID: trackID),
            let destination = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: NSError(domain: "CoreImageTestCompositor", code: 1))
            return
        }
        Self.seenFormats.withLock { _ = $0.insert(CVPixelBufferGetPixelFormatType(destination)) }
        let size = request.renderContext.size
        var image = CIImage(cvPixelBuffer: source)
        image = image.transformed(
            by: CGAffineTransform(
                scaleX: size.width / image.extent.width, y: size.height / image.extent.height))
        context.render(image, to: destination)
        request.finish(withComposedVideoFrame: destination)
    }
}

/// A compositor that never finishes a request until AVFoundation cancels it, to prove a wedged render
/// surfaces as an error instead of a frozen progress bar.
final class HangingTestCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAsynchronousVideoCompositionRequest] = []

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA,
        ]
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.withLock { pending.append(request) }
    }

    func cancelAllPendingVideoCompositionRequests() {
        let requests = lock.withLock {
            defer { pending.removeAll() }
            return pending
        }
        for request in requests { request.finishCancelledRequest() }
    }
}
