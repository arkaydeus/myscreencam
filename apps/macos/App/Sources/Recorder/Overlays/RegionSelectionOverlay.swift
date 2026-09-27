import AppKit
import CoreGraphics

/// Drag-to-select a screen region: a transparent panel over every display with a crosshair. Drag to draw a
/// rectangle (live W×H label, everything outside dimmed), drag inside it to move it or drag elsewhere to draw a
/// new one. Return or "Record" confirms and starts recording, "Use Region" only selects, Esc cancels.
///
/// The result is in the chosen display's points with the origin at its top-left, as `ScreenSource.region`
/// expects (the overlay views are flipped and cover their screen exactly, so view coordinates are exactly that).
@MainActor
final class RegionSelectionOverlay {
    enum Outcome {
        case cancelled
        case selected(RecorderPreferences.Region, startRecording: Bool)
    }

    /// The one overlay on screen, kept alive until it finishes.
    private static var current: RegionSelectionOverlay?

    fileprivate private(set) var selection: RecorderPreferences.Region?
    private var panels: [RegionPanel] = []
    private let completion: (Outcome) -> Void

    private init(initial: RecorderPreferences.Region?, completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        if let initial, ScreenGeometry.screen(for: initial.displayID) != nil { selection = initial }
    }

    /// Shows the overlay on every display. Any overlay already showing is cancelled first.
    static func present(initial: RecorderPreferences.Region?, completion: @escaping (Outcome) -> Void) {
        current?.finish(.cancelled)
        let overlay = RegionSelectionOverlay(initial: initial, completion: completion)
        current = overlay
        overlay.open()
    }

    private func open() {
        let mouse = NSEvent.mouseLocation
        var keyPanel: RegionPanel?
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let panel = RegionPanel(screen: screen)
            let view = RegionSelectionView(overlay: self, displayID: displayID)
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
            if screen.frame.contains(mouse) { keyPanel = panel }
        }
        NSApp.activate()
        let key = keyPanel ?? panels.first
        key?.makeKeyAndOrderFront(nil)
        if let key { _ = key.makeFirstResponder(key.contentView) }
        NSCursor.crosshair.set()
    }

    fileprivate func setSelection(_ selection: RecorderPreferences.Region?) {
        self.selection = selection
        for panel in panels { (panel.contentView as? RegionSelectionView)?.selectionChanged() }
    }

    fileprivate func confirm(startRecording: Bool) {
        guard let selection, selection.rect.width >= 2, selection.rect.height >= 2 else { return }
        finish(.selected(selection, startRecording: startRecording))
    }

    fileprivate func finish(_ outcome: Outcome) {
        guard Self.current === self else { return }
        Self.current = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
        completion(outcome)
    }
}

private final class RegionPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
}

private final class RegionSelectionView: NSView {
    private unowned let overlay: RegionSelectionOverlay
    private let displayID: CGDirectDisplayID
    private let controls = NSStackView()
    private var dragMode: DragMode?

    private enum DragMode {
        case draw(anchor: CGPoint)
        case move(offset: CGSize)
    }

    init(overlay: RegionSelectionOverlay, displayID: CGDirectDisplayID) {
        self.overlay = overlay
        self.displayID = displayID
        super.init(frame: .zero)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        let use = NSButton(title: "Use Region", target: self, action: #selector(useRegion))
        let record = NSButton(title: "Record", target: self, action: #selector(recordRegion))
        record.bezelColor = AppTheme.record
        record.keyEquivalent = "\r"
        use.bezelColor = AppTheme.accent
        for button in [cancel, use, record] { button.bezelStyle = .push }
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        controls.appearance = AppTheme.appearance
        controls.wantsLayer = true
        controls.layer?.backgroundColor = AppTheme.panelBackground.withAlphaComponent(0.95).cgColor
        controls.layer?.borderColor = AppTheme.panelBorder.cgColor
        controls.layer?.borderWidth = 1
        controls.layer?.cornerRadius = 10
        controls.setViews([cancel, use, record], in: .leading)
        controls.isHidden = true
        addSubview(controls)
        selectionChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var ownSelection: CGRect? {
        guard let selection = overlay.selection, selection.displayID == displayID else { return nil }
        return selection.rect
    }

    func selectionChanged() {
        needsDisplay = true
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        guard let rect = ownSelection, dragMode == nil else {
            controls.isHidden = true
            return
        }
        controls.isHidden = false
        let size = controls.fittingSize
        var origin = CGPoint(x: rect.maxX - size.width, y: rect.maxY + 10)
        if origin.y + size.height > bounds.maxY - 8 { origin.y = rect.maxY - size.height - 10 }
        origin.x = min(max(bounds.minX + 8, origin.x), bounds.maxX - size.width - 8)
        controls.frame = CGRect(origin: origin, size: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.windowBackground.withAlphaComponent(0.4).setFill()
        bounds.fill()
        guard let rect = ownSelection else {
            if overlay.selection == nil { drawHint() }
            return
        }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        AppTheme.accent.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.stroke()
        drawSizeLabel(for: rect)
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: AppTheme.primaryText,
        ]
        let size = text.size(withAttributes: attributes)
        var box = CGRect(x: rect.minX, y: rect.minY - size.height - 10, width: size.width + 12, height: size.height + 6)
        if box.minY < bounds.minY + 4 { box.origin.y = rect.minY + 6 }
        box.origin.x = min(max(bounds.minX + 4, box.minX), bounds.maxX - box.width - 4)
        AppTheme.panelBackground.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attributes)
    }

    private func drawHint() {
        let text = "Drag to select a region to record · Esc to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: AppTheme.primaryText,
        ]
        let size = text.size(withAttributes: attributes)
        let box = CGRect(
            x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 10, width: size.width + 32,
            height: size.height + 20)
        AppTheme.panelBackground.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        text.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 10), withAttributes: attributes)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let rect = ownSelection { addCursorRect(rect, cursor: .openHand) }
        if !controls.isHidden { addCursorRect(controls.frame, cursor: .arrow) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if let rect = ownSelection, rect.contains(point) {
            dragMode = .move(offset: CGSize(width: point.x - rect.minX, height: point.y - rect.minY))
            NSCursor.closedHand.set()
        } else {
            dragMode = .draw(anchor: clamp(point))
            overlay.setSelection(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .draw(let anchor):
            let end = clamp(point)
            let rect = CGRect(
                x: min(anchor.x, end.x), y: min(anchor.y, end.y), width: abs(end.x - anchor.x),
                height: abs(end.y - anchor.y)
            ).integral
            overlay.setSelection(RecorderPreferences.Region(displayID: displayID, rect: rect))
        case .move(let offset):
            guard let rect = ownSelection else { return }
            var origin = CGPoint(x: point.x - offset.width, y: point.y - offset.height)
            origin.x = min(max(bounds.minX, origin.x), bounds.maxX - rect.width).rounded()
            origin.y = min(max(bounds.minY, origin.y), bounds.maxY - rect.height).rounded()
            overlay.setSelection(
                RecorderPreferences.Region(displayID: displayID, rect: CGRect(origin: origin, size: rect.size)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
        if let rect = ownSelection, rect.width < 4 || rect.height < 4 {
            overlay.setSelection(nil)
        } else {
            overlay.setSelection(overlay.selection)
        }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(bounds.minX, point.x), bounds.maxX), y: min(max(bounds.minY, point.y), bounds.maxY))
    }

    // MARK: Keys and buttons

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: overlay.finish(.cancelled)  // Esc
        case 36, 76: overlay.confirm(startRecording: true)  // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { overlay.finish(.cancelled) }

    @objc private func cancelSelection() { overlay.finish(.cancelled) }
    @objc private func useRegion() { overlay.confirm(startRecording: false) }
    @objc private func recordRegion() { overlay.confirm(startRecording: true) }
}
