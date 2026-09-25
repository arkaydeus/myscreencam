import AppKit

/// Draws export progress over the Dock icon. Redrawn only when the whole-percent value changes.
@MainActor
final class ExportDockProgress {
    private var view: DockProgressView?

    func show(fraction: Double) {
        let tile = NSApp.dockTile
        let view: DockProgressView
        if let existing = self.view {
            view = existing
        } else {
            view = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            self.view = view
            tile.contentView = view
        }
        view.fraction = min(max(fraction, 0), 1)
        tile.display()
    }

    func clear() {
        guard view != nil else { return }
        view = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

private final class DockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let height = max(8, bounds.height * 0.1)
        let track = NSRect(
            x: bounds.width * 0.1, y: bounds.height * 0.08, width: bounds.width * 0.8, height: height)
        let radius = height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let inset = track.insetBy(dx: 1.5, dy: 1.5)
        var bar = inset
        bar.size.width = max(inset.height, inset.width * fraction)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
    }
}
