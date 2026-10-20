import ExportKit
import Foundation
import ProjectKit
import RenderKit
import Testing

@testable import MyScreenCam

struct ExportSizingTests {
    @Test(arguments: ExportPreset.allCases, ExportScale.allCases)
    func croppedPlansMatchCanvasAndPresetCaps(preset: ExportPreset, scale: ExportScale) {
        let source = CGSize(width: 7680, height: 4320)
        let crop = NormRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        for enabled in [false, true] {
            for aspect in OutputAspect.allCases {
                let background = BackgroundSettings(enabled: enabled, aspect: aspect, padding: 0.17)
                var settings = preset.settings
                settings.scale = scale
                let natural = ExportSizing.naturalCanvas(sourceSize: source, crop: crop, background: background)
                let expected: CGSize
                if enabled {
                    switch aspect {
                    case .square: expected = CGSize(width: 3840, height: 3840)
                    case .standard4x3: expected = CGSize(width: 3840, height: 2880)
                    case .portrait9x16: expected = CGSize(width: 3840, height: 3840 * 16.0 / 9)
                    default: expected = CGSize(width: 3840, height: 2160)
                    }
                } else {
                    expected = CGSize(width: 3840, height: 2160)
                }
                #expect(natural == expected)
                let plan = ExportSizing.plan(sourceSize: source, crop: crop, background: background, settings: settings)
                let layout = CanvasLayout.make(
                    sourceSize: source, crop: crop, background: background, sizing: plan.renderSizing)
                #expect(plan.renderSize == layout.canvasSize)
                #expect(plan.outputSize == settings.outputSize(forSource: expected))
                #expect(abs(plan.renderSize.width - plan.outputSize.width) <= 2)
                #expect(abs(plan.renderSize.height - plan.outputSize.height) <= 2)
                let long = max(plan.renderSize.width, plan.renderSize.height)
                let short = min(plan.renderSize.width, plan.renderSize.height)
                #expect(long <= Double(settings.maxLongEdge ?? settings.format.maximumDimensions.longEdge) + 2)
                #expect(short <= Double(settings.maxShortEdge ?? settings.format.maximumDimensions.shortEdge) + 2)
                #expect(Int(plan.renderSize.width) % 2 == 0 && Int(plan.renderSize.height) % 2 == 0)
            }
        }
    }

    @Test func fractionalCropSnapsBeforeSizingAndPaddingDoesNotEnlargeCanvas() {
        let source = CGSize(width: 1001, height: 777)
        let crop = NormRect(x: 0.123, y: 0.234, w: 0.456, h: 0.345)
        var background = BackgroundSettings(enabled: false)
        let shown = CanvasLayout.sourceCrop(crop, sourceSize: source).size
        #expect(shown == CGSize(width: 457, height: 268))
        #expect(ExportSizing.naturalCanvas(sourceSize: source, crop: crop, background: background) == shown)
        background.enabled = true
        background.aspect = .square
        let natural = ExportSizing.naturalCanvas(sourceSize: source, crop: crop, background: background)
        #expect(natural == CGSize(width: 457, height: 457))
        for padding in [0.0, 0.2, 0.45] {
            background.padding = padding
            let plan = ExportSizing.plan(
                sourceSize: source, crop: crop, background: background, settings: ExportPreset.gif.settings)
            #expect(plan.outputSize == CGSize(width: 458, height: 458))
            #expect(plan.renderSize == plan.outputSize)
            #expect(
                CanvasLayout.make(sourceSize: source, crop: crop, background: background, sizing: plan.renderSizing)
                    .canvasSize == plan.renderSize)
        }
    }
}
