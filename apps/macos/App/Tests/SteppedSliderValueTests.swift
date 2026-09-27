import SwiftUI
import Testing

@testable import MyScreenCam

@MainActor
struct SteppedSliderValueTests {
    @Test func snapsFromNonzeroAndNegativeLowerBounds() {
        #expect(SteppedSliderValue.snap(1.124, in: 1.1...4, step: 0.05) == 1.1)
        #expect(abs(SteppedSliderValue.snap(1.126, in: 1.1...4, step: 0.05) - 1.15) < 1e-10)
        #expect(abs(SteppedSliderValue.snap(-4.92, in: -5...5, step: 0.05) - -4.9) < 1e-10)
        #expect(SteppedSliderValue.snap(-4.75, in: -5...5, step: 0.5) == -4.5)
        #expect(SteppedSliderValue.snap(1.25, in: 1...4, step: 0.5) == 1.5)
    }

    @Test func clampsAndReachesBothEndpoints() {
        #expect(SteppedSliderValue.snap(-1, in: 0...1, step: 0.3) == 0)
        #expect(abs(SteppedSliderValue.snap(0.8, in: 0...1, step: 0.3) - 0.9) < 1e-10)
        #expect(SteppedSliderValue.snap(1, in: 0...1, step: 0.3) == 1)
        #expect(SteppedSliderValue.snap(2, in: 0...1, step: 0.3) == 1)
        #expect(SteppedSliderValue.snap(4, in: 1.1...4, step: 0.05) == 4)
        #expect(SteppedSliderValue.snap(5, in: 1.1...4, step: 0.05) == 4)
    }

    @Test func bindingWritesOnlyWhenTheSnappedValueChanges() {
        var stored = 1.1
        var writes = 0
        let source = Binding(
            get: { stored },
            set: {
                stored = $0; writes += 1
            })
        let stepped = SteppedSliderValue.binding(source, in: 1.1...4, step: 0.05)

        stepped.wrappedValue = 1.12
        #expect(writes == 0)
        stepped.wrappedValue = 1.14
        #expect(abs(stored - 1.15) < 1e-10)
        #expect(writes == 1)
        stepped.wrappedValue = 1.16
        #expect(writes == 1)
        stepped.wrappedValue = 4
        #expect(stored == 4)
        #expect(writes == 2)
    }
}
