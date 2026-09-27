import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One GIF frame's image data: a sub-rectangle of the canvas with its own colour table.
struct GIFFrame {
    /// Position and size on the canvas, in pixels.
    var left: Int
    var top: Int
    var width: Int
    var height: Int
    /// Packed RGB triplets; the entry count is a power of two from 2 to 256.
    var colorTable: Data
    var interlaced: Bool
    var transparentIndex: UInt8?
    /// LZW minimum code size byte, the data sub-blocks and the block terminator.
    var imageData: Data
}

/// Writes a GIF89a stream incrementally, one frame at a time, to a file.
///
/// ImageIO's multi-frame `CGImageDestination` keeps every frame until `finalize` and then needs
/// ≈3 MB per 720p frame, so a long GIF would need gigabytes. Instead each frame is encoded on its own
/// by ImageIO (``GIFFrameEncoder``) and spliced in here, so memory stays at about one frame.
final class GIFStreamWriter {
    private let handle: FileHandle
    private(set) var bytesWritten: Int64 = 0
    private(set) var framesWritten = 0

    /// Creates the file and writes the header, logical screen descriptor and a loop-forever extension.
    init(url: URL, width: Int, height: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        var header = Data("GIF89a".utf8)
        header.appendLittleEndian(UInt16(width))
        header.appendLittleEndian(UInt16(height))
        // No global colour table (every frame carries its own), 8-bit colour resolution.
        header.append(contentsOf: [0x70, 0x00, 0x00])
        // NETSCAPE2.0 application extension: loop count 0 = forever.
        header.append(contentsOf: [0x21, 0xFF, 0x0B])
        header.append(Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        try write(header)
    }

    /// Appends a frame shown for `delayCentiseconds`. Frames are never disposed, so a sub-rectangle
    /// frame draws over the previous image.
    func append(_ frame: GIFFrame, delayCentiseconds: Int) throws {
        var data = Data(capacity: frame.imageData.count + frame.colorTable.count + 32)
        // Graphic control extension.
        let disposalDoNotDispose: UInt8 = 1 << 2
        let transparentFlag: UInt8 = frame.transparentIndex == nil ? 0 : 1
        data.append(contentsOf: [0x21, 0xF9, 0x04, disposalDoNotDispose | transparentFlag])
        data.appendLittleEndian(UInt16(clamping: max(1, delayCentiseconds)))
        data.append(contentsOf: [frame.transparentIndex ?? 0, 0x00])
        // Image descriptor with a local colour table.
        data.append(0x2C)
        data.appendLittleEndian(UInt16(frame.left))
        data.appendLittleEndian(UInt16(frame.top))
        data.appendLittleEndian(UInt16(frame.width))
        data.appendLittleEndian(UInt16(frame.height))
        let entries = frame.colorTable.count / 3
        let sizeBits = UInt8(max(0, Int(log2(Double(max(entries, 2)))) - 1))
        data.append(0x80 | (frame.interlaced ? 0x40 : 0) | sizeBits)
        data.append(frame.colorTable)
        data.append(frame.imageData)
        try write(data)
        framesWritten += 1
    }

    /// Writes the trailer and closes the file.
    func close() throws {
        try write(Data([0x3B]))
        try handle.close()
    }

    /// Closes the file without completing it.
    func abandon() {
        try? handle.close()
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        bytesWritten += Int64(data.count)
    }
}

/// Encodes BGRA frames into GIF frames.
///
/// - Only the rectangle that changed since the previous frame is encoded. Screen recordings are
///   mostly static, so this shrinks files a lot. An unchanged frame returns `nil`, and the caller
///   extends the previous frame's delay.
/// - A pixel counts as changed when a colour channel moves by more than ``tolerance`` levels, so
///   video-codec noise on a static screen doesn't produce frames. Comparisons are against the last
///   *encoded* pixels, so slow changes still register once they add up to more than the tolerance.
/// - ImageIO does the colour quantisation (a 256-colour palette per frame) and the LZW coding.
///
/// Reads the pixel buffer on the CPU. That's unavoidable for GIF, and at GIF sizes it's cheap.
final class GIFFrameEncoder {
    /// Per-channel change (out of 255) below which a pixel is considered unchanged. GIF's 256-colour
    /// palettes are far coarser than this.
    static let tolerance: Int32 = 4

    let width: Int
    let height: Int
    private let stride: Int
    private let previous: UnsafeMutableRawPointer
    private var hasPrevious = false
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.stride = width * 4
        self.previous = UnsafeMutableRawPointer.allocate(byteCount: width * 4 * height, alignment: 64)
    }

    deinit {
        previous.deallocate()
    }

    /// Encodes the part of `pixelBuffer` (32BGRA, `width`×`height`) that differs from the last frame.
    func encode(_ pixelBuffer: CVPixelBuffer) throws(ExportError) -> GIFFrame? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
            CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height
        else {
            throw .gifEncodingFailed("The compositor returned an unexpected frame format or size.")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw .gifEncodingFailed("The frame has no pixel data.")
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let rect = changedRect(base: base, sourceStride: sourceStride) else { return nil }
        // Keep the new pixels for the next comparison and as the backing store for this frame's image.
        for row in rect.top..<(rect.top + rect.height) {
            let offset = rect.left * 4
            (previous + row * stride + offset).copyMemory(
                from: base + row * sourceStride + offset, byteCount: rect.width * 4)
        }
        hasPrevious = true
        return try encodeRegion(rect)
    }

    private struct Region {
        var left: Int
        var top: Int
        var width: Int
        var height: Int
    }

    /// The bounding box of pixels whose colour differs from the previous frame (alpha ignored).
    private func changedRect(base: UnsafeMutableRawPointer, sourceStride: Int) -> Region? {
        guard hasPrevious else { return Region(left: 0, top: 0, width: width, height: height) }
        let rowBytes = width * 4
        func pixels(_ row: Int) -> (UnsafePointer<UInt32>, UnsafePointer<UInt32>)? {
            let current = base + row * sourceStride
            let old = previous + row * stride
            guard memcmp(current, old, rowBytes) != 0 else { return nil }
            return (
                UnsafePointer(current.assumingMemoryBound(to: UInt32.self)),
                UnsafePointer(old.assumingMemoryBound(to: UInt32.self))
            )
        }
        func rowDiffers(_ row: Int) -> Bool {
            guard let (a, b) = pixels(row) else { return false }
            for x in 0..<width where Self.differs(a[x], b[x]) { return true }
            return false
        }
        guard let top = (0..<height).first(where: rowDiffers) else { return nil }
        let bottom = (top..<height).last(where: rowDiffers) ?? top
        var minX = width
        var maxX = -1
        for row in top...bottom {
            guard let (a, b) = pixels(row) else { continue }
            var x = 0
            while x < minX {
                if Self.differs(a[x], b[x]) {
                    minX = x
                    break
                }
                x += 1
            }
            x = width - 1
            while x > maxX {
                if Self.differs(a[x], b[x]) {
                    maxX = x
                    break
                }
                x -= 1
            }
        }
        guard maxX >= minX else { return nil }
        return Region(left: minX, top: top, width: maxX - minX + 1, height: bottom - top + 1)
    }

    /// Whether two BGRA pixels differ by more than ``tolerance`` in any colour channel.
    @inline(__always)
    private static func differs(_ a: UInt32, _ b: UInt32) -> Bool {
        guard (a ^ b) & 0x00FF_FFFF != 0 else { return false }
        let blue = Int32(a & 0xFF) - Int32(b & 0xFF)
        let green = Int32((a >> 8) & 0xFF) - Int32((b >> 8) & 0xFF)
        let red = Int32((a >> 16) & 0xFF) - Int32((b >> 16) & 0xFF)
        return abs(blue) > tolerance || abs(green) > tolerance || abs(red) > tolerance
    }

    /// Encodes a region of `previous` with ImageIO and extracts the frame from the single-image GIF.
    private func encodeRegion(_ rect: Region) throws(ExportError) -> GIFFrame {
        let byteCount = (rect.height - 1) * stride + rect.width * 4
        let origin = previous + rect.top * stride + rect.left * 4
        guard
            let provider = CGDataProvider(
                dataInfo: nil, data: origin, size: byteCount, releaseData: { _, _, _ in }),
            let image = CGImage(
                width: rect.width, height: rect.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw .gifEncodingFailed("Couldn't wrap the frame in a CGImage.")
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.gif.identifier as CFString, 1, nil)
        else {
            throw .gifEncodingFailed("ImageIO has no GIF encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw .gifEncodingFailed("ImageIO couldn't encode a frame.")
        }
        guard var frame = GIFParser.firstFrame(in: data as Data) else {
            throw .gifEncodingFailed("ImageIO produced a GIF that couldn't be parsed.")
        }
        frame.left = rect.left
        frame.top = rect.top
        return frame
    }
}

/// Extracts the first image (with its effective colour table) from a GIF byte stream.
enum GIFParser {
    static func firstFrame(in data: Data) -> GIFFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { return nil }
        var index = 13
        var globalTable: Data?
        let screenFlags = bytes[10]
        if screenFlags & 0x80 != 0 {
            let length = 3 << ((Int(screenFlags) & 0x07) + 1)
            guard index + length <= bytes.count else { return nil }
            globalTable = Data(bytes[index..<(index + length)])
            index += length
        }
        var transparentIndex: UInt8?
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:  // Extension: label, then data sub-blocks.
                guard index + 1 < bytes.count else { return nil }
                let label = bytes[index + 1]
                index += 2
                if label == 0xF9, index + 4 < bytes.count, bytes[index] == 4, bytes[index + 1] & 0x01 != 0 {
                    transparentIndex = bytes[index + 4]
                }
                guard let end = skipSubBlocks(bytes, from: index) else { return nil }
                index = end
            case 0x2C:  // Image descriptor.
                guard index + 10 <= bytes.count else { return nil }
                let width = Int(bytes[index + 5]) | Int(bytes[index + 6]) << 8
                let height = Int(bytes[index + 7]) | Int(bytes[index + 8]) << 8
                let flags = bytes[index + 9]
                index += 10
                var table = globalTable
                if flags & 0x80 != 0 {
                    let length = 3 << ((Int(flags) & 0x07) + 1)
                    guard index + length <= bytes.count else { return nil }
                    table = Data(bytes[index..<(index + length)])
                    index += length
                }
                guard let colorTable = table, index < bytes.count else { return nil }
                let dataStart = index
                guard let end = skipSubBlocks(bytes, from: index + 1) else { return nil }
                return GIFFrame(
                    left: 0, top: 0, width: width, height: height,
                    colorTable: colorTable,
                    interlaced: flags & 0x40 != 0,
                    transparentIndex: transparentIndex,
                    imageData: Data(bytes[dataStart..<end]))
            default:
                return nil
            }
        }
        return nil
    }

    /// Returns the index just past the block terminator of the sub-blocks starting at `start`.
    private static func skipSubBlocks(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            if length == 0 { return index }
            index += length
        }
        return nil
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }
}
