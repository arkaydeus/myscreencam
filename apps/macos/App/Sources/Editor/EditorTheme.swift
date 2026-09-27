import AppKit
import SwiftUI

/// The editor's "Midnight Glass" look: a deep navy window, floating rounded panels, a green accent and standard
/// rounded-rectangle buttons. The editor always renders dark. AppKit colours are the source; `Color` mirrors them.
enum EditorTheme {
    // MARK: Surfaces

    static let windowBackground = NSColor(hex: 0x070A14)
    static let panelBackground = NSColor(hex: 0x0F1526)
    static let stageBackground = NSColor(hex: 0x0B1020)
    static let rowBackground = NSColor(hex: 0x141B30)
    static let panelBorder = NSColor.white.withAlphaComponent(0.08)
    static let controlFill = NSColor.white.withAlphaComponent(0.06)
    static let controlBorder = NSColor.white.withAlphaComponent(0.09)

    // MARK: Text

    static let primaryText = NSColor(hex: 0xE6EAF5)
    static let secondaryText = NSColor(hex: 0x9AA5C2)
    static let tertiaryText = NSColor(hex: 0x66718F)

    // MARK: Accent

    static let accent = NSColor(hex: 0x3DDC97)
    static let onAccent = NSColor(hex: 0x03140C)
    static let destructive = NSColor(hex: 0xFF8FA3)

    // MARK: Timeline tracks

    static let screenTrack = accent
    static let webcamTrack = NSColor(hex: 0x5B7CFF)
    static let systemAudioTrack = NSColor(hex: 0xB18CFF)
    static let microphoneTrack = NSColor(hex: 0x7CB8FF)
    static let zoomTrack = NSColor(hex: 0xFFB25B)
    static let blurTrack = NSColor(hex: 0xFF6FAE)
    static let subtitleTrack = NSColor(hex: 0x4FD1E8)
    static let clickMarker = NSColor(hex: 0xFFE066)
    static let playhead = NSColor(hex: 0xFF5C8A)

    // MARK: Metrics

    static let panelRadius: CGFloat = 14
    static let panelGap: CGFloat = 8
    static let controlRadius: CGFloat = 6
}

extension Color {
    static let editorAccent = Color(nsColor: EditorTheme.accent)
    static let editorOnAccent = Color(nsColor: EditorTheme.onAccent)
    static let editorPrimaryText = Color(nsColor: EditorTheme.primaryText)
    static let editorSecondaryText = Color(nsColor: EditorTheme.secondaryText)
    static let editorTertiaryText = Color(nsColor: EditorTheme.tertiaryText)
    static let editorPanel = Color(nsColor: EditorTheme.panelBackground)
    static let editorStage = Color(nsColor: EditorTheme.stageBackground)
    static let editorWindow = Color(nsColor: EditorTheme.windowBackground)
    static let editorControlFill = Color(nsColor: EditorTheme.controlFill)
    static let editorControlBorder = Color(nsColor: EditorTheme.controlBorder)
    static let editorPanelBorder = Color(nsColor: EditorTheme.panelBorder)
    static let editorDestructive = Color(nsColor: EditorTheme.destructive)
    static let editorZoom = Color(nsColor: EditorTheme.zoomTrack)
}

extension NSColor {
    /// An sRGB colour from `0xRRGGBB`.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    /// A floating editor panel: filled, rounded, with a hairline border.
    func editorPanel(_ fill: Color = .editorPanel) -> some View {
        let shape = RoundedRectangle(cornerRadius: EditorTheme.panelRadius, style: .continuous)
        return background(fill)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.editorPanelBorder))
    }
}

/// The editor's text buttons: 28 pt rounded rectangles.
struct EditorButtonStyle: ButtonStyle {
    enum Kind {
        case standard, primary, destructive
    }

    var kind: Kind = .standard

    func makeBody(configuration: Configuration) -> some View {
        EditorButtonBody(configuration: configuration, kind: kind)
    }

    private struct EditorButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: EditorTheme.controlRadius, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(background, in: shape)
                .overlay(shape.strokeBorder(kind == .primary ? Color.clear : Color.editorControlBorder))
                .shadow(color: kind == .primary ? Color.editorAccent.opacity(0.28) : .clear, radius: 9, y: 4)
                .contentShape(shape)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }

        private var foreground: Color {
            switch kind {
            case .standard: .editorPrimaryText
            case .primary: .editorOnAccent
            case .destructive: .editorDestructive
            }
        }

        private var background: Color {
            kind == .primary ? .editorAccent : .editorControlFill
        }
    }
}

/// Borderless icon buttons (transport, timeline zoom): a 30 pt square that tints while pressed.
struct EditorIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        EditorIconButtonBody(configuration: configuration)
    }

    private struct EditorIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: EditorTheme.controlRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isEnabled ? Color.editorPrimaryText : Color.editorTertiaryText)
                .frame(width: 30, height: 30)
                .background(configuration.isPressed ? Color.editorControlFill : .clear, in: shape)
                .contentShape(shape)
        }
    }
}

extension ButtonStyle where Self == EditorButtonStyle {
    static var editor: EditorButtonStyle { EditorButtonStyle() }
    static var editorPrimary: EditorButtonStyle { EditorButtonStyle(kind: .primary) }
    static var editorDestructive: EditorButtonStyle { EditorButtonStyle(kind: .destructive) }
}

extension ButtonStyle where Self == EditorIconButtonStyle {
    static var editorIcon: EditorIconButtonStyle { EditorIconButtonStyle() }
}
