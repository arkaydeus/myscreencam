import AppKit
import CaptureKit
import QuartzCore
import SwiftUI

/// Receives mic levels (~30 Hz) and pushes them straight into the meter's layers, bypassing SwiftUI.
@MainActor
final class MicLevelSink {
    fileprivate weak var view: MicLevelMeterView.MeterView?

    func update(_ level: AudioLevel) { view?.show(level) }

    func reset() { view?.show(.silence) }
}

/// A horizontal level meter (accent green → amber → record red) drawn by Core Animation layers.
struct MicLevelMeterView: NSViewRepresentable {
    let sink: MicLevelSink

    func makeNSView(context: Context) -> MeterView {
        let view = MeterView()
        sink.view = view
        return view
    }

    func updateNSView(_ view: MeterView, context: Context) {
        sink.view = view
    }

    final class MeterView: NSView {
        private let track = CALayer()
        private let gradient = CAGradientLayer()
        private let mask = CALayer()
        private let peakMarker = CALayer()
        private var level: Float = 0
        private var peak: Float = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            track.backgroundColor = AppTheme.controlFill.cgColor
            track.cornerRadius = 3
            gradient.colors = [AppTheme.accent, AppTheme.accent, AppTheme.warning, AppTheme.record].map(\.cgColor)
            gradient.locations = [0, 0.6, 0.8, 1]
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.cornerRadius = 3
            mask.backgroundColor = NSColor.black.cgColor
            gradient.mask = mask
            peakMarker.backgroundColor = AppTheme.primaryText.withAlphaComponent(0.7).cgColor
            layer?.addSublayer(track)
            layer?.addSublayer(gradient)
            layer?.addSublayer(peakMarker)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.frame = bounds
            gradient.frame = bounds
            applyLevel()
            CATransaction.commit()
        }

        func show(_ reading: AudioLevel) {
            level = Self.meterPosition(reading.rms)
            peak = Self.meterPosition(reading.peak)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyLevel()
            CATransaction.commit()
        }

        private func applyLevel() {
            let width = bounds.width
            mask.frame = CGRect(x: 0, y: 0, width: width * CGFloat(level), height: bounds.height)
            peakMarker.isHidden = peak <= 0.01
            peakMarker.frame = CGRect(x: max(0, width * CGFloat(peak) - 2), y: 0, width: 2, height: bounds.height)
        }

        /// Linear amplitude → 0…1 on a -60…0 dBFS scale.
        static func meterPosition(_ amplitude: Float) -> Float {
            guard amplitude > 0 else { return 0 }
            let decibels = 20 * log10(amplitude)
            return min(1, max(0, (decibels + 60) / 60))
        }
    }
}
