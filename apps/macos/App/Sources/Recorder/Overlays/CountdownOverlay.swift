import AppKit
import Observation
import SwiftUI

/// The large 3-2-1 shown in the middle of the display about to be recorded. A click-through, non-activating
/// panel; it is gone before the capture starts (and our windows are excluded from capture anyway).
@MainActor
final class CountdownOverlay {
    @Observable
    @MainActor
    final class Model {
        var remaining = 3
    }

    private let model = Model()
    private var panel: NSPanel?

    func show(_ remaining: Int, on screen: NSScreen?) {
        model.remaining = remaining
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 220, height: 220)
        let frame = (screen ?? NSScreen.main)?.frame ?? NSRect(origin: .zero, size: size)
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            display: false)
        panel.orderFrontRegardless()
    }

    func update(_ remaining: Int) {
        model.remaining = remaining
    }

    func hide() {
        panel?.orderOut(nil)
        // Nothing to keep between recordings.
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 220),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        return panel
    }
}

private struct CountdownView: View {
    let model: CountdownOverlay.Model

    var body: some View {
        Text("\(model.remaining)")
            .font(.system(size: 120, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.themePrimaryText)
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: model.remaining)
            .frame(width: 220, height: 220)
            .background(Color.themePanel.opacity(0.88), in: RoundedRectangle(cornerRadius: 40, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .strokeBorder(Color.themeAccent.opacity(0.5), lineWidth: 2)
            )
            .accessibilityLabel("Recording starts in \(model.remaining)")
    }
}
