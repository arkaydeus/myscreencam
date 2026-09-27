// Deterministic "busy screen" for recording benchmarks: a window that scrolls page-like content at 60 fps.
// It shows without activating, so it doesn't steal focus, and quits after --seconds (default 70).
//
//   swift scripts/perf/motion-window.swift --seconds 70

import AppKit

let seconds = CommandLine.arguments.firstIndex(of: "--seconds")
    .flatMap { Double(CommandLine.arguments[$0 + 1]) } ?? 70

final class ScrollingPageView: NSView {
    private var offset: CGFloat = 0
    private let rowHeight: CGFloat = 28
    private let palette: [NSColor] = [.systemBlue, .systemPink, .systemGreen, .systemOrange, .systemPurple, .systemTeal]
    private let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15),
        .foregroundColor: NSColor.labelColor,
    ]

    override var isFlipped: Bool { true }

    func tick() {
        offset += 6
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let first = Int(offset / rowHeight)
        let rows = Int(bounds.height / rowHeight) + 2
        for i in 0..<rows {
            let line = first + i
            let y = CGFloat(line) * rowHeight - offset
            if line % 12 == 0 {
                palette[(line / 12) % palette.count].withAlphaComponent(0.8).setFill()
                NSRect(x: 40, y: y, width: bounds.width * 0.4, height: rowHeight * 0.8).fill()
                continue
            }
            let text = "Line \(line) — The quick brown fox jumps over the lazy dog. Lorem ipsum dolor sit amet \(line * 7919 % 10007)."
            text.draw(at: NSPoint(x: 40, y: y + 5), withAttributes: attributes)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.title = "My Screen Cam perf motion"
let view = ScrollingPageView(frame: window.contentLayoutRect)
window.contentView = view
// Place it in the middle of the primary display (the one with the menu bar).
if let screen = NSScreen.screens.first {
    let f = screen.frame
    window.setFrameOrigin(NSPoint(x: f.midX - window.frame.width / 2, y: f.midY - window.frame.height / 2))
}
window.orderFrontRegardless()

Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    MainActor.assumeIsolated { view.tick() }
}
Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
    MainActor.assumeIsolated { app.terminate(nil) }
}
app.run()
