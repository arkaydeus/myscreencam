import AVFoundation
import AudioToolbox
import Foundation
import MediaToolbox

/// Per-track processing inside an `MTAudioProcessingTap`: gain (which may exceed 0 dB, unlike `AVAudioMix`
/// volume), a soft limiter when gaining up, and level metering.
///
/// The context is immutable apart from the stream format, which is written once in the tap's prepare callback
/// before any process callback runs (MediaToolbox guarantees that ordering), hence `@unchecked Sendable`.
final class AudioTapContext: @unchecked Sendable {
    let gain: Float
    let limit: Bool
    let meter: (levels: AudioLevels, kind: AudioTrackKind)?
    private(set) var isFloat32 = false

    init(gain: Float, limit: Bool, meter: (levels: AudioLevels, kind: AudioTrackKind)?) {
        self.gain = gain
        self.limit = limit
        self.meter = meter
    }

    func prepare(format: AudioStreamBasicDescription) {
        isFloat32 =
            format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    /// Applies gain/limiting and meters a block in place.
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard isFloat32 else { return }
        var sumSquares: Float = 0
        var peak: Float = 0
        var count = 0
        let gain = self.gain
        let limit = self.limit
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                var x = samples[i] * gain
                if limit { x = AudioSoftLimiter.process(x) }
                samples[i] = x
                sumSquares += x * x
                peak = max(peak, abs(x))
            }
            count += n
        }
        if let meter, count > 0 {
            meter.levels.publish(meter.kind, rms: (sumSquares / Float(count)).squareRoot(), peak: peak)
        }
    }
}

/// Creates `MTAudioProcessingTap`s for `AVMutableAudioMixInputParameters.audioTapProcessor`.
enum AudioTap {
    /// A tap applying `gain` (linear) with optional limiting and metering, or nil if creation fails.
    static func make(gain: Float, limit: Bool, meter: (levels: AudioLevels, kind: AudioTrackKind)?)
        -> MTAudioProcessingTap?
    {
        let context = AudioTapContext(gain: gain, limit: limit, meter: meter)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: nil,
            process: tapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<AudioTapContext>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }
}

private func context(of tap: MTAudioProcessingTap) -> AudioTapContext {
    Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    context(of: tap).prepare(format: format.pointee)
}

private let tapProcess: MTAudioProcessingTapProcessCallback = {
    tap, frameCount, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    context(of: tap).process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
}
