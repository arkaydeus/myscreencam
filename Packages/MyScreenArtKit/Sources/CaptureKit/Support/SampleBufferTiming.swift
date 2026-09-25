import CoreMedia

extension CMSampleBuffer {
    /// A copy that shares this buffer's media data (pixel buffer or audio block) with every timestamp shifted
    /// by `offset`. Cheap: only the timing array is new.
    public func shifted(by offset: CMTime) -> CMSampleBuffer? {
        retimed { $0 + offset }
    }

    /// A copy that shares this buffer's media data with each presentation/decode timestamp mapped through
    /// `transform`. Invalid timestamps stay invalid.
    public func retimed(_ transform: (CMTime) -> CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard
            CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
                == noErr, count > 0
        else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard
            CMSampleBufferGetSampleTimingInfoArray(
                self, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr
        else { return nil }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = transform(timings[index].presentationTimeStamp)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = transform(timings[index].decodeTimeStamp)
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: self, sampleTimingEntryCount: count,
            sampleTimingArray: &timings, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}
