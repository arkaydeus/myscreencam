import Foundation

/// Seeds zoom keyframes from left clicks (the legacy "Create zooms from clicks" rule).
///
/// For each left mouse-down, in time order:
/// - the zoom starts `leadIn` seconds before the click: `t = max(0, click.t − leadIn)`;
/// - the click is skipped when `t < previousEnd + minimumGap`, where `previousEnd` is the `end` of the last
///   keyframe created;
/// - the keyframe uses mode `.click`, the scale and timing from `defaults`, and targets the click position
///   clamped to 0…1.
///
/// Right clicks, other buttons, moves, ups and scrolls are ignored.
public enum AutoZoom {
    /// Seconds between the start of the ease-in and the click.
    public static let leadIn = 0.12
    /// Minimum gap in seconds between the end of one auto-zoom and the start of the next.
    public static let minimumGap = 0.18

    public static func keyframes(from events: [InputEvent], defaults: ZoomTiming) -> [ZoomKeyframe] {
        let clicks = events.filter { $0.isLeftClick && $0.t.isFinite }.sorted { $0.t < $1.t }
        var result: [ZoomKeyframe] = []
        var previousEnd = -Double.infinity
        for click in clicks {
            let t = max(0, click.t - leadIn)
            if t < previousEnd + minimumGap { continue }
            let keyframe = ZoomKeyframe(
                time: t,
                scale: defaults.scale,
                target: NormPoint(x: click.x, y: click.y).clamped,
                mode: .click,
                easeIn: defaults.easeIn,
                hold: defaults.hold,
                easeOut: defaults.easeOut
            )
            result.append(keyframe)
            previousEnd = keyframe.end
        }
        return result
    }
}

extension EditConfig {
    /// The config a freshly opened recording starts with: ``initial(for:)`` plus, when `autoZoom` is on,
    /// click zooms seeded by ``AutoZoom`` from `events` using the default zoom timing. Keyframes that would
    /// start at or after the end of the recording are dropped.
    public static func makeInitial(meta: RecordingMeta, events: [InputEvent], autoZoom: Bool) -> EditConfig {
        var config = EditConfig.initial(for: meta)
        if autoZoom {
            config.zoom.keyframes = AutoZoom.keyframes(from: events, defaults: config.zoom.defaults)
                .filter { meta.duration <= 0 || $0.time < meta.duration }
        }
        return config
    }
}
