import AppKit
import SwiftUI

/// The app's "Midnight Glass" look: deep navy windows, floating rounded panels, a green accent and standard
/// rounded-rectangle buttons. The whole app always renders dark (``appearance``); every window root applies
/// ``SwiftUI/View/themedWindow()``. AppKit colours are the source; `Color` mirrors them.
enum AppTheme {
    /// The app-wide appearance: menus, alerts, save panels and system controls render dark to match.
    static var appearance: NSAppearance? { NSAppearance(named: .darkAqua) }

    static func applyAppearance() {
        NSApp.appearance = appearance
    }

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
    static let warning = NSColor(hex: 0xFFB25B)
    /// Recording: the Start button, the HUD dot and the region overlay's Record button.
    static let record = NSColor(hex: 0xFF4D6A)

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
    static let themeAccent = Color(nsColor: AppTheme.accent)
    static let themeOnAccent = Color(nsColor: AppTheme.onAccent)
    static let themePrimaryText = Color(nsColor: AppTheme.primaryText)
    static let themeSecondaryText = Color(nsColor: AppTheme.secondaryText)
    static let themeTertiaryText = Color(nsColor: AppTheme.tertiaryText)
    static let themePanel = Color(nsColor: AppTheme.panelBackground)
    static let themeStage = Color(nsColor: AppTheme.stageBackground)
    static let themeRow = Color(nsColor: AppTheme.rowBackground)
    static let themeWindow = Color(nsColor: AppTheme.windowBackground)
    static let themeControlFill = Color(nsColor: AppTheme.controlFill)
    static let themeControlBorder = Color(nsColor: AppTheme.controlBorder)
    static let themePanelBorder = Color(nsColor: AppTheme.panelBorder)
    static let themeDestructive = Color(nsColor: AppTheme.destructive)
    static let themeWarning = Color(nsColor: AppTheme.warning)
    static let themeRecord = Color(nsColor: AppTheme.record)
    static let themeZoom = Color(nsColor: AppTheme.zoomTrack)
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
    /// A floating panel: filled, rounded, with a hairline border.
    func themePanel(_ fill: Color = .themePanel, cornerRadius: CGFloat = AppTheme.panelRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(fill)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.themePanelBorder))
    }

    /// The root of every window and sheet: dark, navy (also under a transparent title bar), green-tinted controls
    /// and the theme's text colour.
    func themedWindow() -> some View {
        foregroundStyle(Color.themePrimaryText)
            .tint(.themeAccent)
            .background(Color.themeWindow)
            .preferredColorScheme(.dark)
            .background(ThemedWindowConfigurator())
    }
}

/// Paints the hosting window navy, so the title bar, toolbar and sheet margins match the content.
private struct ThemedWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView { ConfiguratorView() }

    func updateNSView(_ view: ConfiguratorView, context: Context) {}

    final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.appearance = AppTheme.appearance
            window.titlebarAppearsTransparent = true
            window.backgroundColor = AppTheme.windowBackground
        }
    }
}

/// A group box drawn as a floating panel, its label above the content in secondary text.
struct ThemeGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.themeSecondaryText)
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel(cornerRadius: AppTheme.panelRadius - 4)
    }
}

extension GroupBoxStyle where Self == ThemeGroupBoxStyle {
    static var themed: ThemeGroupBoxStyle { ThemeGroupBoxStyle() }
}

/// The app's text buttons: 28 pt rounded rectangles, or 40 pt for a window's main action.
struct ThemeButtonStyle: ButtonStyle {
    enum Kind {
        case standard, primary, destructive, record
    }

    var kind: Kind = .standard
    var isLarge = false

    func makeBody(configuration: Configuration) -> some View {
        ThemeButtonBody(configuration: configuration, kind: kind, isLarge: isLarge)
    }

    private struct ThemeButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let isLarge: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(
                cornerRadius: isLarge ? AppTheme.controlRadius + 2 : AppTheme.controlRadius, style: .continuous)
            configuration.label
                .font(.system(size: isLarge ? 15 : 13, weight: isFilled ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, isLarge ? 18 : 12)
                .frame(height: isLarge ? 40 : 28)
                .background(background, in: shape)
                .overlay(shape.strokeBorder(isFilled ? Color.clear : Color.themeControlBorder))
                .shadow(color: isFilled ? background.opacity(0.28) : .clear, radius: 9, y: 4)
                .contentShape(shape)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }

        private var isFilled: Bool { kind == .primary || kind == .record }

        private var foreground: Color {
            switch kind {
            case .standard: .themePrimaryText
            case .primary: .themeOnAccent
            case .destructive: .themeDestructive
            case .record: .white
            }
        }

        private var background: Color {
            switch kind {
            case .primary: .themeAccent
            case .record: .themeRecord
            case .standard, .destructive: .themeControlFill
            }
        }
    }
}

/// Borderless icon buttons (transport, timeline zoom, recording HUD): a 30 pt square that tints while pressed.
struct ThemeIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ThemeIconButtonBody(configuration: configuration)
    }

    private struct ThemeIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isEnabled ? Color.themePrimaryText : Color.themeTertiaryText)
                .frame(width: 30, height: 30)
                .background(configuration.isPressed ? Color.themeControlFill : .clear, in: shape)
                .contentShape(shape)
        }
    }
}

extension ButtonStyle where Self == ThemeButtonStyle {
    static var themed: ThemeButtonStyle { ThemeButtonStyle() }
    static var themedPrimary: ThemeButtonStyle { ThemeButtonStyle(kind: .primary) }
    static var themedDestructive: ThemeButtonStyle { ThemeButtonStyle(kind: .destructive) }
    static var themedRecord: ThemeButtonStyle { ThemeButtonStyle(kind: .record) }
}

extension ButtonStyle where Self == ThemeIconButtonStyle {
    static var themedIcon: ThemeIconButtonStyle { ThemeIconButtonStyle() }
}
