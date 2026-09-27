import CoreGraphics
import ProjectKit

/// Row layout and tick spacing for the timeline.
enum TimelineMetrics {
    static let gutter: CGFloat = 78
    static let trailingPad: CGFloat = 14
    static let rulerHeight: CGFloat = 24
    static let rowGap: CGFloat = 3
    static let bottomPad: CGFloat = 6
    /// Timeline zoom bounds (1 = the whole edited duration fits the view).
    static let zoomRange: ClosedRange<Double> = 0.5...4

    enum Row: CaseIterable {
        case screen, webcam, systemAudio, microphone, zoom, blur, subtitles, clicks

        var height: CGFloat {
            switch self {
            case .screen: 34
            case .webcam: 22
            case .systemAudio, .microphone: 30
            case .zoom: 28
            case .blur: 22
            case .subtitles: 22
            case .clicks: 16
            }
        }

        var title: String {
            switch self {
            case .screen: "Screen"
            case .webcam: "Webcam"
            case .systemAudio: "System"
            case .microphone: "Mic"
            case .zoom: "Zoom"
            case .blur: "Blur"
            case .subtitles: "Subtitles"
            case .clicks: "Clicks"
            }
        }
    }

    /// The rows to show: stream rows only for recorded streams, the Subtitles row only when there are subtitles.
    static func rows(for streams: Set<StreamKind>, subtitles: Bool = false) -> [Row] {
        Row.allCases.filter { row in
            switch row {
            case .webcam: streams.contains(.webcam)
            case .systemAudio: streams.contains(.systemAudio)
            case .microphone: streams.contains(.microphone)
            case .subtitles: subtitles
            default: true
            }
        }
    }

    static func preferredHeight(for streams: Set<StreamKind>, subtitles: Bool = false) -> CGFloat {
        rulerHeight + rows(for: streams, subtitles: subtitles).reduce(0) { $0 + $1.height + rowGap } + bottomPad
    }

    /// Major/minor tick spacing in seconds so major ticks are at least `minimumSpacing` points apart.
    static func tickSteps(pointsPerSecond pps: Double, minimumSpacing: Double = 72) -> (major: Double, minor: Double) {
        let steps: [(Double, Double)] = [
            (0.1, 0.05), (0.2, 0.05), (0.5, 0.1), (1, 0.25), (2, 0.5), (5, 1), (10, 2), (15, 5), (30, 5), (60, 15),
            (120, 30), (300, 60), (600, 120), (1800, 300), (3600, 600),
        ]
        for (major, minor) in steps where major * pps >= minimumSpacing { return (major, minor) }
        return steps.last!
    }

    /// Ruler label for a tick.
    static func tickLabel(_ t: Double, major: Double) -> String {
        let total = max(0, t)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        if major < 1 {
            return minutes > 0 ? String(format: "%d:%04.1f", minutes, seconds) : String(format: "%.1fs", seconds)
        }
        return String(format: "%d:%02d", minutes, Int(seconds.rounded()))
    }
}
