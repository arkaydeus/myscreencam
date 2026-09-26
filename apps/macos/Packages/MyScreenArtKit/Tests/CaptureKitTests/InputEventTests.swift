import CoreGraphics
import Darwin
import ProjectKit
import Testing

@testable import CaptureKit

/// Synthesised events: `CGEvent` construction doesn't need any permission.
private func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, ticks: UInt64) -> CGEvent {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
    event.timestamp = ticks
    return event
}

private func seconds(_ s: Double) -> UInt64 {
    // Convert seconds to mach ticks for synthetic timestamps.
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return UInt64(s * 1_000_000_000 * Double(info.denom) / Double(info.numer))
}

struct PointerNormalizerTests {
    let rect = CGRect(x: 100, y: 50, width: 800, height: 400)

    @Test func normalisesAgainstContentRect() {
        let p = PointerNormalizer.normalize(CGPoint(x: 500, y: 250), in: rect)
        #expect(p.x == 0.5 && p.y == 0.5)
        let outside = PointerNormalizer.normalize(CGPoint(x: 0, y: 450), in: rect)
        #expect(outside.x == -0.125 && outside.y == 1)
    }

    @Test func mapsButtonsAndDrags() throws {
        let cases: [(CGEventType, CGMouseButton, InputEvent.Kind, Int?)] = [
            (.mouseMoved, .left, .move, nil),
            (.leftMouseDown, .left, .down, 0),
            (.leftMouseUp, .left, .up, 0),
            (.leftMouseDragged, .left, .move, 0),
            (.rightMouseDown, .right, .down, 1),
            (.rightMouseDragged, .right, .move, 1),
            (.otherMouseDown, .center, .down, 2),
            (.otherMouseUp, .center, .up, 2),
        ]
        for (type, button, kind, expectedButton) in cases {
            let event = mouse(type, at: CGPoint(x: 300, y: 150), button: button, ticks: 1)
            let pointer = try #require(
                PointerNormalizer.pointerEvent(from: event, type: type, hostTime: 7, contentRect: rect))
            #expect(pointer.kind == kind, "\(type.rawValue)")
            #expect(pointer.button == expectedButton, "\(type.rawValue)")
            #expect(pointer.x == 0.25 && pointer.y == 0.25)
            #expect(pointer.hostTime == 7)
        }
    }

    @Test func mapsScrollDeltas() throws {
        let event = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 5, wheel3: 0))
        event.location = CGPoint(x: 500, y: 250)
        let pointer = try #require(
            PointerNormalizer.pointerEvent(from: event, type: .scrollWheel, hostTime: 1, contentRect: rect))
        #expect(pointer.kind == .scroll)
        #expect(pointer.dy == -12)
        #expect(pointer.dx == 5)
    }

    @Test func ignoresOtherEventTypes() {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        #expect(PointerNormalizer.pointerEvent(from: event, type: .keyDown, hostTime: 0, contentRect: rect) == nil)
    }

    @Test func buildsEventsFileRecord() {
        let pointer = PointerEvent(hostTime: 3, kind: .down, location: .zero, x: 0.1, y: 0.2, button: 0)
        #expect(
            pointer.inputEvent(sessionTime: 1.5, cursor: 4)
                == InputEvent(t: 1.5, kind: .down, x: 0.1, y: 0.2, button: 0, cursor: 4))
    }
}

struct InputEventProcessorTests {
    @Test func tracksAMovingWindowAtMostTenTimesASecond() {
        let start = seconds(1000)
        nonisolated(unsafe) var frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
        nonisolated(unsafe) var lookups = 0
        let provider: (CGWindowID) -> CGRect? = { _ in
            lookups += 1
            return frame
        }
        var processor = InputEventProcessor(
            tracker: ContentRectTracker(mode: .window(42), rect: frame), minimumMoveInterval: 0)

        func move(_ t: Double, _ point: CGPoint) -> PointerEvent? {
            let ticks = start + seconds(t)
            let outputs = processor.process(
                type: .mouseMoved, event: mouse(.mouseMoved, at: point, ticks: ticks), nowTicks: ticks,
                frameProvider: provider)
            guard case .event(let pointer) = outputs.last else { return nil }
            return pointer
        }

        #expect(move(0, CGPoint(x: 500, y: 250))?.x == 0.5)
        frame.origin.x = 500  // the window moves right by 500 pt
        // Within 100 ms of the last lookup the cached frame is used.
        #expect(move(0.05, CGPoint(x: 500, y: 250))?.x == 0.5)
        #expect(lookups == 1)
        // After 100 ms the frame is re-read and the same global point is now at the window's left edge.
        #expect(move(0.11, CGPoint(x: 500, y: 250))?.x == 0)
        #expect(move(0.12, CGPoint(x: 1000, y: 250))?.x == 0.5)
        #expect(lookups == 2)
    }

    @Test func reportsClosedWindowOnce() {
        let start = seconds(50)
        var processor = InputEventProcessor(
            tracker: ContentRectTracker(mode: .window(7), rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        let first = processor.process(
            type: .leftMouseDown, event: mouse(.leftMouseDown, at: .zero, ticks: start), nowTicks: start,
            frameProvider: { _ in nil })
        #expect(first.first == .sourceGone)
        let later = start + seconds(1)
        let second = processor.process(
            type: .leftMouseUp, event: mouse(.leftMouseUp, at: .zero, ticks: later), nowTicks: later,
            frameProvider: { _ in nil })
        #expect(!second.contains(.sourceGone))
        #expect(second.count == 1)
    }

    @Test func coalescesMovesButKeepsButtons() {
        let start = seconds(10)
        var processor = InputEventProcessor(
            tracker: ContentRectTracker(mode: .fixed, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
            minimumMoveInterval: 1.0 / 240)
        var emitted: [InputEvent.Kind] = []
        // 1 kHz mouse for 20 ms, with a click in the middle.
        for ms in 0..<20 {
            let ticks = start + seconds(Double(ms) / 1000)
            let type: CGEventType = ms == 10 ? .leftMouseDown : .mouseMoved
            for case .event(let pointer) in processor.process(
                type: type, event: mouse(type, at: CGPoint(x: ms, y: 0), ticks: ticks), nowTicks: ticks,
                frameProvider: { _ in nil })
            {
                emitted.append(pointer.kind)
            }
        }
        #expect(emitted.filter { $0 == .down }.count == 1)
        // Moves pass at 0, 5, 11 and 16 ms (each ≥ 4.17 ms after the last one that passed).
        #expect(emitted.filter { $0 == .move }.count == 4)
    }

    @Test func eventTimesAreHostSeconds() {
        let ticks = mach_absolute_time()
        var processor = InputEventProcessor(
            tracker: ContentRectTracker(mode: .fixed, rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let outputs = processor.process(
            type: .leftMouseDown, event: mouse(.leftMouseDown, at: .zero, ticks: ticks - seconds(0.003)),
            nowTicks: ticks, frameProvider: { _ in nil })
        guard case .event(let pointer) = outputs.first else {
            Issue.record("no event")
            return
        }
        #expect(abs(pointer.hostTime - (HostClock.seconds(machTicks: ticks) - 0.003)) < 1e-6)
    }
}
