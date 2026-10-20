import Foundation
import ProjectKit
import RenderKit
import SpeechCore

/// A candidate transcript adoption that needs the user's decisions on conflicting edits.
struct PendingMerge: Equatable {
    let revisionID: String
    let conflicts: [SubtitleMerge.Conflict]
    /// Conflicts resolved as "keep mine".
    var keep: Set<SubtitleCue.ID>
}

/// Subtitle editing: cues, their placement and style, transcript-driven cuts and adopting new transcripts.
/// Every change is an ordinary undoable edit of `edit.subtitles` (or of the segments, for cuts).
extension EditorModel {
    // MARK: Transcripts

    /// The revision the cues were built from.
    var transcript: TranscriptRevision? { edit.subtitles.revisionID.flatMap { transcripts[$0] } }

    /// A newer revision waiting to be adopted.
    var candidateTranscript: TranscriptRevision? { edit.subtitles.candidateRevisionID.flatMap { transcripts[$0] } }

    /// Reads the adopted and candidate revisions from the package (off the main actor).
    func loadTranscripts() {
        let ids = [edit.subtitles.revisionID, edit.subtitles.candidateRevisionID].compactMap { $0 }
            .filter { transcripts[$0] == nil }
        guard !ids.isEmpty else { return }
        let package = self.package
        Task { [weak self] in
            let loaded = await Task.detached {
                ids.compactMap { try? package.loadTranscript(id: $0) }
            }.value
            guard let self else { return }
            for revision in loaded { self.transcripts[revision.id] = revision }
            self.fillWordTimings()
        }
    }

    /// Cues built before word timing was stored get it from their transcript. Not an undo step: it's derived data,
    /// and nothing on screen changes unless word highlighting is on.
    private func fillWordTimings() {
        guard let transcript else { return }
        applyDerived { _ = $0.subtitles.fillWordTimings(from: transcript) }
    }

    /// Lands a finished transcription (called by `TranscriptionCenter`): cues are rebuilt when the user hasn't
    /// edited any, otherwise the revision becomes a candidate.
    func receiveTranscript(_ revision: TranscriptRevision) -> SubtitleSettings.Receipt {
        transcripts[revision.id] = revision
        var receipt = SubtitleSettings.Receipt.candidate
        update("Generate Subtitles") { receipt = $0.subtitles.receive(revision) }
        if receipt == .adopted, edit.subtitles.cues.isEmpty == false, inspectorTab != .subtitles {
            flash("Subtitles ready")
        }
        return receipt
    }

    /// Adopts the candidate. Without conflicts it's immediate; otherwise the user resolves them first
    /// (``pendingMerge``), then ``finishPendingMerge()``.
    func adoptCandidate() {
        guard let candidate = candidateTranscript else { return }
        let preview = SubtitleMerge.merge(current: edit.subtitles.cues, newRevision: candidate)
        if preview.conflicts.isEmpty {
            update("Use New Transcript") { _ = $0.subtitles.adopt(candidate) }
            selectedWordIDs = []
            if preview.reapplied > 0 {
                flash(preview.reapplied == 1 ? "1 correction kept" : "\(preview.reapplied) corrections kept")
            }
        } else {
            pendingMerge = PendingMerge(revisionID: candidate.id, conflicts: preview.conflicts, keep: [])
        }
    }

    func finishPendingMerge() {
        guard let pending = pendingMerge, let candidate = transcripts[pending.revisionID] else {
            pendingMerge = nil
            return
        }
        pendingMerge = nil
        update("Use New Transcript") { _ = $0.subtitles.adopt(candidate, keep: pending.keep) }
        selectedWordIDs = []
    }

    func discardCandidate() {
        update("Discard Transcript") { $0.subtitles.candidateRevisionID = nil }
        pendingMerge = nil
    }

    // MARK: Cues

    var selectedCueIDs: Set<SubtitleCue.ID> {
        if case .cues(let ids) = selection { ids } else { [] }
    }

    /// The selected cue when exactly one is selected (the one the cue editor and preview handles edit).
    var selectedCue: SubtitleCue? {
        let ids = selectedCueIDs
        guard ids.count == 1, let id = ids.first else { return nil }
        return edit.subtitles.cues.first { $0.id == id }
    }

    /// Selects a cue from a click (plain, ⌘ or ⇧).
    func selectCue(_ id: SubtitleCue.ID, _ modifier: SelectionModifier = .replace) {
        let next = SelectionModifier.select(
            id, modifier, current: selectedCueIDs, anchor: cueAnchor, ordered: edit.subtitles.cues.map(\.id))
        if next.ids != [id] || selectedCue?.id != id { selectedWordIDs = [] }
        cueAnchor = next.anchor
        selection = next.ids.isEmpty ? nil : .cues(next.ids)
    }

    /// Selects every cue (clicking the timeline's Subtitles label).
    func selectAllCues() {
        let ids = Set(edit.subtitles.cues.map(\.id))
        guard !ids.isEmpty else { return }
        selectedWordIDs = []
        cueAnchor = edit.subtitles.cues.first?.id
        selection = .cues(ids)
        inspectorTab = .subtitles
    }

    /// The first cue showing at the playhead.
    var cueAtPlayhead: SubtitleCue? { edit.subtitles.activeCues(at: currentSourceTime).first }

    func updateCue(
        _ id: SubtitleCue.ID, _ action: String, coalesce: AnyHashable? = nil, _ change: (inout SubtitleCue) -> Void
    ) {
        update(action, coalesce: coalesce) { edit in
            guard let i = edit.subtitles.cues.firstIndex(where: { $0.id == id }) else { return }
            change(&edit.subtitles.cues[i])
        }
    }

    /// Selects a cue, pauses and moves the playhead into it.
    func focusCue(_ id: SubtitleCue.ID) {
        guard let cue = edit.subtitles.cues.first(where: { $0.id == id }) else { return }
        selectCue(id)
        pause()
        // A little into the cue so it's the one showing.
        seek(to: timeline.editedTimeSnapping(forSource: cue.start + min(0.05, cue.duration / 2)))
    }

    func setCueText(_ id: SubtitleCue.ID, _ text: String) {
        updateCue(id, "Edit Subtitle", coalesce: AnyHashable(["cue-text", id.uuidString])) { $0.text = text }
    }

    /// Sets a cue's start/end (source seconds), keeping at least ``EditLimits/minimumCueLength``.
    func setCueTiming(_ id: SubtitleCue.ID, start: Double? = nil, end: Double? = nil) {
        updateCue(id, "Subtitle Timing", coalesce: AnyHashable(["cue-time", id.uuidString])) { cue in
            let minimum = EditLimits.minimumCueLength
            if let start { cue.start = min(max(0, start), cue.end - minimum) }
            if let end { cue.end = max(min(meta.duration, end), cue.start + minimum) }
            cue.timingEdited = true
        }
    }

    /// Moves a whole cue in time (a timeline drag; wrap in a continuous change).
    func moveCue(_ id: SubtitleCue.ID, toStart start: Double) {
        updateCue(id, "Move Subtitle") { cue in
            let length = cue.duration
            let old = cue.start
            cue.start = min(max(0, start), max(0, meta.duration - length))
            cue.end = cue.start + length
            cue.timingEdited = true
            // The words move with the cue, so the highlight stays in step with the text.
            let delta = cue.start - old
            for i in cue.words.indices {
                cue.words[i].start += delta
                cue.words[i].end += delta
            }
        }
    }

    /// Gives a cue its own position (a preview drag; wrap in a continuous change).
    func setCuePosition(_ id: SubtitleCue.ID, _ position: NormPoint?) {
        updateCue(id, position == nil ? "Reset Subtitle Position" : "Move Subtitle") { $0.position = position }
    }

    /// Gives a cue its own wrap width (fraction of the canvas width), or nil for the style's (a preview edge drag;
    /// wrap in a continuous change).
    func setCueWidth(_ id: SubtitleCue.ID, _ width: Double?) {
        updateCue(id, width == nil ? "Reset Subtitle Width" : "Subtitle Width") { $0.maxWidth = width }
    }

    /// Makes a cue's own width the style's width, and clears every cue's own width.
    func useCueWidthAsDefault(_ id: SubtitleCue.ID) {
        guard let width = edit.subtitles.cues.first(where: { $0.id == id })?.maxWidth else { return }
        update("Default Subtitle Width") { edit in
            edit.subtitles.style.maxWidth = width
            for i in edit.subtitles.cues.indices { edit.subtitles.cues[i].maxWidth = nil }
        }
    }

    func resetAllCuePositions() {
        update("Reset Subtitle Positions") { edit in
            for i in edit.subtitles.cues.indices { edit.subtitles.cues[i].position = nil }
        }
    }

    /// Makes a moved cue's position the default for every cue: the placement anchor nearest to it and its margin.
    func useCuePositionAsDefault(_ id: SubtitleCue.ID) {
        guard let cue = edit.subtitles.cues.first(where: { $0.id == id }), let position = cue.position else { return }
        let canvas = renderer.layout.canvasSize
        let frame = SubtitleLayout.frame(for: cue, settings: edit.subtitles, canvasSize: canvas)
        update("Default Subtitle Position") { edit in
            if position.y < 0.34 {
                edit.subtitles.placement = SubtitlePlacement(anchor: .top, margin: frame.minY / max(canvas.height, 1))
            } else if position.y > 0.66 {
                edit.subtitles.placement = SubtitlePlacement(
                    anchor: .bottom, margin: (canvas.height - frame.maxY) / max(canvas.height, 1))
            } else {
                edit.subtitles.placement = SubtitlePlacement(anchor: .middle, margin: edit.subtitles.placement.margin)
            }
            for i in edit.subtitles.cues.indices { edit.subtitles.cues[i].position = nil }
        }
    }

    /// Adds an empty two-second cue at the playhead (manual timing) and selects it.
    func addCueAtPlayhead() {
        let start = currentSourceTime
        guard start < meta.duration - EditLimits.minimumCueLength else {
            flash("Move the playhead before the end")
            return
        }
        let cue = SubtitleCue(start: start, end: min(meta.duration, start + 2), text: "", timingEdited: true)
        update("Add Subtitle") { $0.subtitles.cues.append(cue) }
        selectCue(cue.id)
        inspectorTab = .subtitles
    }

    func deleteCues(_ ids: Set<SubtitleCue.ID>) {
        update(ids.count == 1 ? "Delete Subtitle" : "Delete Subtitles") {
            $0.subtitles.cues.removeAll { ids.contains($0.id) }
        }
    }

    // MARK: Transcript-driven cuts

    /// The transcript words of a cue with their text (for the word chips).
    func words(of cue: SubtitleCue) -> [(unit: TranscriptUnit, text: String)] {
        guard let transcript else { return [] }
        let ids = Set(cue.unitIDs)
        return transcript.segments.flatMap { segment in
            segment.units.compactMap { unit in
                guard ids.contains(unit.id), unit.kind != .punctuation, let text = segment.text(of: unit) else {
                    return nil
                }
                return (unit, text)
            }
        }
    }

    /// Why the selected words can't be cut, or nil when they can.
    var wordCutProblem: String? {
        guard let transcript else { return "No transcript" }
        guard !selectedWordIDs.isEmpty else { return "Select words to cut" }
        do {
            _ = try TranscriptCuts.sourceRange(of: selectedWordIDs, in: transcript)
            return nil
        } catch .noFineTiming {
            return "These words don't have precise timing"
        } catch .notContiguous {
            return "Select neighbouring words"
        } catch {
            return "Select words to cut"
        }
    }

    /// Removes the selected words' time from the video (an ordinary, undoable cut). In the same undo step the words
    /// leave their subtitle's text, unless the user has rewritten that text (then it's theirs to change).
    func cutSelectedWords() {
        guard let transcript else { return }
        do {
            let range = try TranscriptCuts.sourceRange(of: selectedWordIDs, in: transcript)
            var next = try edit.removingSource(start: range.start, end: range.end)
            let removed = Set(selectedWordIDs)
            if let i = next.subtitles.cues.firstIndex(where: { !removed.isDisjoint(with: $0.unitIDs) }) {
                var cue = next.subtitles.cues[i]
                let spoken = words(of: cue).filter { removed.contains($0.unit.id) }.map(\.text)
                if !cue.isTextCorrected, let trimmed = Self.removing(spoken, from: cue.text) {
                    let originalUnits = transcript.allUnits.compactMap { segment, unit -> (String, UnitTiming?)? in
                        guard cue.unitIDs.contains(unit.id), let text = segment.text(of: unit) else { return nil }
                        return (text, unit.timing)
                    }
                    let sourceStart = originalUnits.compactMap { $0.1?.sourceRange.startSeconds }.first
                    let moveOffset = sourceStart.flatMap { source in cue.words.first.map { $0.start - source } } ?? 0
                    cue.text = trimmed
                    cue.generatedText = trimmed
                    cue.unitIDs.removeAll { removed.contains($0) }
                    let remainingUnits = transcript.allUnits.compactMap { segment, unit -> (String, UnitTiming?)? in
                        guard cue.unitIDs.contains(unit.id), let text = segment.text(of: unit) else { return nil }
                        return (text, unit.timing)
                    }
                    cue.words = SubtitleWords.build(text: trimmed, units: remainingUnits)
                    for j in cue.words.indices {
                        cue.words[j].start += moveOffset
                        cue.words[j].end += moveOffset
                    }
                    next.subtitles.cues[i] = cue
                }
            }
            apply(next, action: "Cut Words")
            selectedWordIDs = []
        } catch is TranscriptCutError {
            flash(wordCutProblem ?? "Can't cut these words")
        } catch SegmentEditError.lastSegment {
            flash("Can't cut everything")
        } catch {
            flash("Nothing to cut")
        }
    }

    /// `text` without the run of `words` (Latin words or adjacent CJK characters), or nil if not found.
    static func removing(_ words: [String], from text: String) -> String? {
        guard !words.isEmpty else { return nil }
        let cjk = words.allSatisfy {
            !$0.isEmpty
                && $0.unicodeScalars.allSatisfy { scalar in
                    switch scalar.value {
                    case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
                    default: false
                    }
                }
        }
        let boundary = cjk ? "" : "(?<![\\p{L}\\p{N}'])"
        let trailingBoundary = cjk ? "" : "(?![\\p{L}\\p{N}'])"
        let pattern =
            boundary + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: cjk ? "\\s*" : "\\s+")
            + trailingBoundary
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range, in: text)
        else { return nil }
        var result = text
        result.removeSubrange(range)
        return result.replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".").trimmingCharacters(in: .whitespaces)
    }

    /// Removes a whole cue's time range from the video.
    func cutCue(_ id: SubtitleCue.ID) {
        guard let cue = edit.subtitles.cues.first(where: { $0.id == id }) else { return }
        if cue.coarse {
            flash("This subtitle's timing is approximate")
            return
        }
        cutSource(start: cue.start, end: cue.end, action: "Cut Subtitle")
    }

    private func cutSource(start: Double, end: Double, action: String) {
        do {
            apply(try edit.removingSource(start: start, end: end), action: action)
        } catch .lastSegment {
            flash("Can't cut everything")
        } catch {
            flash("Nothing to cut")
        }
    }

    // MARK: Search

    var subtitleMatches: [SubtitleCue.ID] { TranscriptSearch.matches(subtitleSearch, in: edit.subtitles.cues) }

    /// Jumps to the next (or previous) match after the selected cue.
    func jumpToMatch(forward: Bool) {
        let matches = subtitleMatches
        guard !matches.isEmpty else { return }
        let cues = edit.subtitles.cues
        let current = selectedCue.flatMap { cue in cues.firstIndex { $0.id == cue.id } } ?? (forward ? -1 : cues.count)
        let ordered = cues.enumerated().filter { matches.contains($0.element.id) }
        let next =
            forward
            ? (ordered.first { $0.offset > current } ?? ordered.first)
            : (ordered.last { $0.offset < current } ?? ordered.last)
        if let next { focusCue(next.element.id) }
    }
}
