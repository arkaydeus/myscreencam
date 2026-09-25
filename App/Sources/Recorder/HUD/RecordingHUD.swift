import AppKit
import QuartzCore
import SwiftUI

/// The floating recording controls: a small non-activating panel (it never steals focus from the app being
/// recorded) on every Space, draggable by its background, remembering where it was left. Our app's windows are
/// excluded from the capture, and the panel also opts out of window sharing.
@MainActor
final class RecordingHUD {
    private static let autosaveName = "RecordingHUD"
    private static let size = NSSize(width: 292, height: 44)

    private unowned let controller: RecordingController
    private var panel: NSPanel?

    init(controller: RecordingController) {
        self.controller = controller
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel else { return }
        panel.saveFrame(usingName: Self.autosaveName)
        panel.orderOut(nil)
        // Rebuilt for the next recording: no views or observation linger between recordings.
        panel.contentView = nil
        self.panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstMouseHostingView(rootView: RecordingHUDView(controller: controller))
        if !panel.setFrameUsingName(Self.autosaveName) || !Self.isOnScreen(panel.frame) {
            panel.setFrameOrigin(Self.defaultOrigin())
        }
        panel.setContentSize(Self.size)
        return panel
    }

    /// Top centre of the main screen, just under the menu bar.
    private static func defaultOrigin() -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12)
    }

    private static func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons respond to the first click even though the panel never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RecordingHUDView: View {
    let controller: RecordingController
    @State private var confirmingDiscard = false

    var body: some View {
        HStack(spacing: 10) {
            if confirmingDiscard {
                Text("Discard this recording?")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Keep") { confirmingDiscard = false }
                    .keyboardShortcut(.cancelAction)
                Button("Discard", role: .destructive) {
                    confirmingDiscard = false
                    Task { await controller.discard() }
                }
                .tint(.red)
            } else {
                RecordingDot(paused: controller.isPaused)
                    .frame(width: 12, height: 12)
                Text(formatElapsed(controller.elapsedSeconds))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(controller.isPaused ? .secondary : .primary)
                    .frame(minWidth: 58, alignment: .leading)
                Spacer(minLength: 4)
                Button {
                    controller.togglePause()
                } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                }
                .help(controller.isPaused ? "Resume recording" : "Pause recording")
                .accessibilityLabel(controller.isPaused ? "Resume" : "Pause")
                Button {
                    Task { await controller.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Finish the recording and open it in the editor")
                Button {
                    confirmingDiscard = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Discard the recording")
                .accessibilityLabel("Discard")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(width: 292, height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .gesture(WindowDragGesture())
    }
}

/// A red dot that pulses while recording. The pulse is a Core Animation animation, so it runs in the window
/// server without re-rendering any SwiftUI.
private struct RecordingDot: NSViewRepresentable {
    let paused: Bool

    func makeNSView(context: Context) -> DotView { DotView() }

    func updateNSView(_ view: DotView, context: Context) { view.setPaused(paused) }

    final class DotView: NSView {
        private let dot = CALayer()
        private var paused: Bool?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            dot.backgroundColor = NSColor.systemRed.cgColor
            layer?.addSublayer(dot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            dot.frame = bounds
            dot.cornerRadius = min(bounds.width, bounds.height) / 2
        }

        func setPaused(_ paused: Bool) {
            guard paused != self.paused else { return }
            self.paused = paused
            dot.removeAllAnimations()
            dot.backgroundColor = (paused ? NSColor.systemOrange : NSColor.systemRed).cgColor
            guard !paused else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
    }
}
