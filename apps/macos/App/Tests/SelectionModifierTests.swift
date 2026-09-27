import AppKit
import Testing

@testable import MyScreenArt_Dev

@MainActor
struct SelectionModifierTests {
    private let ordered = ["a", "b", "c", "d", "e"]

    @Test func modifierFlagsMapToModifiers() {
        #expect(SelectionModifier([]) == .replace)
        #expect(SelectionModifier(.command) == .toggle)
        #expect(SelectionModifier(.shift) == .range)
        #expect(SelectionModifier([.shift, .command]) == .range)
    }

    @Test func plainClickSelectsOnlyTheItem() {
        let next = SelectionModifier.select("c", .replace, current: ["a", "b"], anchor: "a", ordered: ordered)
        #expect(next.ids == ["c"])
        #expect(next.anchor == "c")
    }

    @Test func commandClickAddsAndRemoves() {
        let added = SelectionModifier.select("d", .toggle, current: ["a"], anchor: "a", ordered: ordered)
        #expect(added.ids == ["a", "d"])
        #expect(added.anchor == "d")

        let removed = SelectionModifier.select("d", .toggle, current: added.ids, anchor: "d", ordered: ordered)
        #expect(removed.ids == ["a"])
        #expect(removed.anchor == nil)

        let removedOther = SelectionModifier.select("a", .toggle, current: ["a", "d"], anchor: "d", ordered: ordered)
        #expect(removedOther.ids == ["d"])
        #expect(removedOther.anchor == "d")
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchor() {
        let forward = SelectionModifier.select("d", .range, current: ["b"], anchor: "b", ordered: ordered)
        #expect(forward.ids == ["b", "c", "d"])
        #expect(forward.anchor == "b")

        // A second ⇧-click re-ranges from the same anchor, in either direction.
        let backward = SelectionModifier.select("a", .range, current: forward.ids, anchor: "b", ordered: ordered)
        #expect(backward.ids == ["a", "b"])
        #expect(backward.anchor == "b")
    }

    @Test func shiftClickWithoutASelectedAnchorSelectsOnlyTheItem() {
        let empty = SelectionModifier.select("c", .range, current: [], anchor: nil, ordered: ordered)
        #expect(empty.ids == ["c"])
        #expect(empty.anchor == "c")

        let stale = SelectionModifier.select("c", .range, current: ["e"], anchor: "a", ordered: ordered)
        #expect(stale.ids == ["c"])
        #expect(stale.anchor == "c")
    }
}
