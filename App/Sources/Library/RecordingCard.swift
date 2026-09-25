import ProjectKit
import SwiftUI

/// One recording in the Library grid: still, duration badge, name, date and stream icons. Hovering shows "Open".
struct RecordingCard: View {
    let item: ProjectKit.LibraryItem
    let isSelected: Bool
    /// Width of the card in points (the grid column width), used to decode the still at display size.
    let width: CGFloat
    let loader: ThumbnailLoader
    let open: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var loadFailed = false
    @State private var isHovering = false

    private static let aspect: CGFloat = 16 / 10

    private var maxPixelSize: Int { ThumbnailLoader.bucket(Double(width * displayScale)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(item.meta.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.meta.createdAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    streamIcons
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovering = $0 }
        .task(id: maxPixelSize) { await loadImage() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.meta.name), \(Self.durationText(item.meta.duration))")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Open", open)
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.85))
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: loadFailed ? "film" : "photo")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.35))
            }
            if isHovering {
                Rectangle().fill(.black.opacity(0.3))
                Button("Open", action: open)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            Text(Self.durationText(item.meta.duration))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var streamIcons: some View {
        HStack(spacing: 5) {
            ForEach(Self.streamOrder, id: \.kind) { entry in
                if item.streams.contains(entry.kind) {
                    Image(systemName: entry.symbol)
                        .help(entry.label)
                        .accessibilityLabel(entry.label)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private static let streamOrder: [(kind: StreamKind, symbol: String, label: String)] = [
        (.screen, "display", "Screen"),
        (.webcam, "web.camera", "Webcam"),
        (.systemAudio, "speaker.wave.2", "System audio"),
        (.microphone, "mic", "Microphone"),
    ]

    private func loadImage() async {
        if let cached = loader.cachedImage(for: item, maxPixelSize: maxPixelSize) {
            image = cached
            return
        }
        let loaded = await loader.image(for: item, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        if let loaded { image = loaded } else if image == nil { loadFailed = true }
    }

    /// "1:05", or "1:02:03" for an hour or more.
    static func durationText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
