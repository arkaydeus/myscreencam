import CoreGraphics
import Foundation
import ProjectKit

/// Everything the renderer needs from a recording package, loaded once.
public struct RenderProject: Sendable {
    public var package: RecordingPackage
    public var meta: RecordingMeta
    public var edit: EditConfig
    public var events: [InputEvent]
    public var cursorIndex: CursorIndex

    public init(
        package: RecordingPackage, meta: RecordingMeta, edit: EditConfig, events: [InputEvent],
        cursorIndex: CursorIndex
    ) {
        self.package = package
        self.meta = meta
        self.edit = edit
        self.events = events
        self.cursorIndex = cursorIndex
    }

    /// Reads meta, edit (or `EditConfig.initial(for:)` when none is saved), events and the cursor index.
    /// Synchronous file I/O: call it off the main actor for long recordings.
    public static func load(_ package: RecordingPackage) throws -> RenderProject {
        let meta = try package.loadMeta()
        let edit = try package.loadEdit() ?? EditConfig.initial(for: meta)
        return RenderProject(
            package: package, meta: meta, edit: edit, events: try package.loadEvents(),
            cursorIndex: try package.loadCursorIndex())
    }

    /// Screen pixel size from the metadata.
    public var sourceSize: CGSize { CGSize(width: meta.screen.pixelWidth, height: meta.screen.pixelHeight) }
}

/// What a composition is built for.
public struct RenderOptions: Sendable, Equatable {
    public enum Purpose: Sendable, Equatable {
        /// Editor playback: audio taps always installed so `AudioLevels` meters work.
        case preview
        /// File export: taps only where gain exceeds 0 dB.
        case export
    }

    public var purpose: Purpose
    /// Output frames per second (the video composition's frame duration). Frames are resampled to this rate.
    public var frameRate: Int
    public var sizing: RenderSizing

    public init(purpose: Purpose, frameRate: Int, sizing: RenderSizing) {
        self.purpose = purpose
        self.frameRate = frameRate
        self.sizing = sizing
    }

    /// Preview options: render at most `maxSize` (the view's backing size), at `frameRate`.
    public static func preview(maxSize: CGSize? = nil, frameRate: Int = 60) -> RenderOptions {
        RenderOptions(
            purpose: .preview, frameRate: frameRate,
            sizing: maxSize.map { .fit(width: $0.width, height: $0.height) } ?? .scale(1))
    }

    /// Export options: `scale` of the natural canvas (1, 0.75, 0.5) at `frameRate`.
    public static func export(scale: Double = 1, frameRate: Int = 30) -> RenderOptions {
        RenderOptions(purpose: .export, frameRate: frameRate, sizing: .scale(scale))
    }
}
