import Foundation

/// Valid ranges for edit values. ``EditConfig/normalized(duration:)`` clamps into these; UI sliders should use
/// them as their bounds.
public enum EditLimits {
    /// Zoom scale (keyframes and defaults).
    public static let zoomScale: ClosedRange<Double> = 1...4
    /// Webcam width as a fraction of the output width.
    public static let webcamWidth: ClosedRange<Double> = 0.05...0.5
    /// Webcam corner radius as a fraction of the overlay's shorter side.
    public static let webcamCornerRadius: ClosedRange<Double> = 0...0.5
    /// Webcam manual sync nudge in seconds.
    public static let webcamSyncOffset: ClosedRange<Double> = -5...5
    /// Blur radius in source pixels.
    public static let blurIntensity: ClosedRange<Double> = 1...50
    /// Per-track gain in dB.
    public static let gainDB: ClosedRange<Double> = -20...10
    /// Click-highlight radius in output points.
    public static let clickHighlightRadius: ClosedRange<Double> = 10...100
    /// Click-highlight duration in seconds.
    public static let clickHighlightDuration: ClosedRange<Double> = 0.1...1
    /// Drag-trail sample count.
    public static let dragTrailLength: ClosedRange<Int> = 2...15
    /// Background padding as a fraction of the canvas's shorter side.
    public static let backgroundPadding: ClosedRange<Double> = 0...0.3
    /// Background content corner radius as a fraction of the content's shorter side.
    public static let backgroundCornerRadius: ClosedRange<Double> = 0...0.2
    /// Shortest segment the segment-editing operations will produce, and the edge tolerance for cuts (seconds).
    public static let minimumSegmentLength = 0.1
}

extension EditConfig {
    /// A copy with every value made valid for a recording of `duration` seconds. Idempotent.
    ///
    /// - Segments: clamped to 0…duration, empty ones dropped, sorted by start, overlapping ones merged (touching
    ///   segments stay separate, since a cut produces them). If none remain, one segment covering the whole
    ///   recording (reusing the first segment's id when there was one).
    /// - Zoom: defaults and keyframes clamped (scale ``EditLimits/zoomScale``, durations ≥ 0, time 0…duration,
    ///   targets 0…1); keyframes sorted by time.
    /// - Webcam: origin 0…1, width ``EditLimits/webcamWidth``, corner radius ``EditLimits/webcamCornerRadius``,
    ///   sync offset ``EditLimits/webcamSyncOffset``.
    /// - Cursor: idle delay ≥ 0, click highlight and drag trail within their ``EditLimits``, trail opacity 0…1.
    /// - Blur: times clamped to 0…duration and masks without `end > start` dropped; rect kept inside 0…1;
    ///   intensity ``EditLimits/blurIntensity``.
    /// - Audio: gains ``EditLimits/gainDB``.
    /// - Background: padding, corner radius and shadow within their ranges.
    /// - Subtitles: style within its ``EditLimits``; cue times clamped to 0…duration, cues without `end > start`
    ///   dropped, positions inside 0…1, cues sorted by start.
    ///
    /// Non-finite numbers are replaced by the nearest sensible value (the range's lower bound, or the default).
    public func normalized(duration: Double) -> EditConfig {
        let duration = duration.isFinite ? max(0, duration) : 0
        var config = self
        config.segments = Self.normalizedSegments(segments, duration: duration)
        config.zoom = zoom.normalized(duration: duration)
        config.webcam = webcam.normalized()
        config.cursor = cursor.normalized()
        config.blur = blur.compactMap { $0.normalized(duration: duration) }
        config.audio.system.gainDB = clamp(audio.system.gainDB, EditLimits.gainDB, fallback: 0)
        config.audio.microphone.gainDB = clamp(audio.microphone.gainDB, EditLimits.gainDB, fallback: 0)
        config.background = background.normalized()
        config.subtitles = subtitles.normalized(duration: duration)
        return config
    }

    static func normalizedSegments(_ segments: [Segment], duration: Double) -> [Segment] {
        let range = 0...duration
        let clamped =
            segments
            .map {
                Segment(id: $0.id, start: clamp($0.start, range, fallback: 0), end: clamp($0.end, range, fallback: 0))
            }
            .filter { $0.end > $0.start }
            .sorted { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }
        var merged: [Segment] = []
        for segment in clamped {
            if let last = merged.last, segment.start < last.end {
                merged[merged.count - 1].end = max(last.end, segment.end)
            } else {
                merged.append(segment)
            }
        }
        if merged.isEmpty {
            merged = [Segment(id: segments.first?.id ?? UUID(), start: 0, end: duration)]
        }
        return merged
    }
}

extension ZoomTiming {
    func normalized() -> ZoomTiming {
        let fallback = ZoomTiming()
        return ZoomTiming(
            scale: clamp(scale, EditLimits.zoomScale, fallback: fallback.scale),
            easeIn: nonNegative(easeIn, fallback: fallback.easeIn),
            hold: nonNegative(hold, fallback: fallback.hold),
            easeOut: nonNegative(easeOut, fallback: fallback.easeOut)
        )
    }
}

extension ZoomSettings {
    func normalized(duration: Double) -> ZoomSettings {
        var zoom = self
        zoom.defaults = defaults.normalized()
        zoom.keyframes =
            keyframes
            .map { keyframe in
                var k = keyframe
                k.time = clamp(k.time, 0...duration, fallback: 0)
                k.scale = clamp(k.scale, EditLimits.zoomScale, fallback: zoom.defaults.scale)
                k.target = k.target.normalized()
                k.easeIn = nonNegative(k.easeIn, fallback: zoom.defaults.easeIn)
                k.hold = nonNegative(k.hold, fallback: zoom.defaults.hold)
                k.easeOut = nonNegative(k.easeOut, fallback: zoom.defaults.easeOut)
                return k
            }
            .sorted { ($0.time, $0.id.uuidString) < ($1.time, $1.id.uuidString) }
        return zoom
    }
}

extension WebcamSettings {
    func normalized() -> WebcamSettings {
        var webcam = self
        let fallback = WebcamSettings()
        webcam.origin = origin.normalized()
        webcam.width = clamp(width, EditLimits.webcamWidth, fallback: fallback.width)
        webcam.cornerRadius = clamp(cornerRadius, EditLimits.webcamCornerRadius, fallback: fallback.cornerRadius)
        webcam.syncOffset = clamp(syncOffset, EditLimits.webcamSyncOffset, fallback: 0)
        return webcam
    }
}

extension CursorSettings {
    func normalized() -> CursorSettings {
        var cursor = self
        let fallback = CursorSettings()
        cursor.idleDelay = nonNegative(idleDelay, fallback: fallback.idleDelay)
        cursor.clickHighlight.radius = clamp(
            clickHighlight.radius, EditLimits.clickHighlightRadius, fallback: fallback.clickHighlight.radius)
        cursor.clickHighlight.duration = clamp(
            clickHighlight.duration, EditLimits.clickHighlightDuration, fallback: fallback.clickHighlight.duration)
        cursor.dragTrail.length = min(
            max(dragTrail.length, EditLimits.dragTrailLength.lowerBound), EditLimits.dragTrailLength.upperBound)
        cursor.dragTrail.opacity = clamp(dragTrail.opacity, 0...1, fallback: fallback.dragTrail.opacity)
        return cursor
    }
}

extension BlurMask {
    /// Nil when the mask has no duration inside the recording.
    func normalized(duration: Double) -> BlurMask? {
        var mask = self
        mask.start = clamp(start, 0...duration, fallback: 0)
        mask.end = clamp(end, 0...duration, fallback: 0)
        guard mask.end > mask.start else { return nil }
        let x = clamp(rect.x, 0...1, fallback: 0)
        let y = clamp(rect.y, 0...1, fallback: 0)
        mask.rect = NormRect(
            x: x, y: y, w: clamp(rect.w, 0...(1 - x), fallback: 0), h: clamp(rect.h, 0...(1 - y), fallback: 0))
        mask.intensity = clamp(intensity, EditLimits.blurIntensity, fallback: 20)
        return mask
    }
}

extension BackgroundSettings {
    func normalized() -> BackgroundSettings {
        var background = self
        let fallback = BackgroundSettings()
        background.padding = clamp(padding, EditLimits.backgroundPadding, fallback: fallback.padding)
        background.cornerRadius = clamp(
            cornerRadius, EditLimits.backgroundCornerRadius, fallback: fallback.cornerRadius)
        background.shadow = clamp(shadow, 0...1, fallback: fallback.shadow)
        return background
    }
}

extension NormPoint {
    fileprivate func normalized() -> NormPoint {
        NormPoint(x: clamp(x, 0...1, fallback: 0.5), y: clamp(y, 0...1, fallback: 0.5))
    }
}

/// Clamps into `range`; NaN becomes `fallback` (itself clamped), ±∞ the nearest bound.
func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
    if value.isNaN { return min(max(fallback, range.lowerBound), range.upperBound) }
    return min(max(value, range.lowerBound), range.upperBound)
}

private func nonNegative(_ value: Double, fallback: Double) -> Double {
    value.isFinite ? max(0, value) : max(0, fallback)
}
