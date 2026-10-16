import Foundation
import TranscriberCore

/// Timing commands: the Shift Times and Timing Post-Processor sheets, the
/// waveform's handles, and the playback ranges of the Playback menu.
extension SubtitleEditorViewModel {
    /// Which lines Shift Times moves (Aegisub's "Affect").
    enum ShiftScope: CaseIterable {
        case selectedLines
        case allLines
        case selectedLineOnward
    }

    /// What a Playback command plays.
    enum PlaybackRange {
        case activeLine
        case selection
        case beforeStart
        case afterStart
        case beforeEnd
        case afterEnd
    }

    /// How far the before/after playback commands reach (Aegisub's 500 ms).
    static let playbackContext = AudioTime(milliseconds: 500)

    func lineIndices(for scope: ShiftScope) -> [Int] {
        switch scope {
        case .selectedLines: selection
        case .allLines: Array(lines.indices)
        case .selectedLineOnward: activeIndex.map { Array($0..<lines.count) } ?? []
        }
    }

    func shift(by offset: AudioTime, changing edges: SubtitleEditing.TimeEdges, scope: ShiftScope) {
        let indices = lineIndices(for: scope)
        guard isEditable, offset != .zero, !indices.isEmpty else { return }
        let outcome = SubtitleEditing.shift(indices, by: offset, changing: edges, in: lines)
        replace(lines: outcome.lines, selection: scope == .allLines ? selection : outcome.selection, actionName: String(localized: "Shift Times"))
    }

    /// How many lines the post-processor would change, for the sheet's summary.
    func postProcessingChangeCount(_ settings: TimingPostProcessing.Settings, allLines: Bool, sound: [SpeechSpan]) -> Int {
        let outcome = TimingPostProcessing.processed(allLines ? [] : selection, in: lines, settings: settings, speech: sound)
        return zip(outcome.lines, lines).filter { $0 != $1 }.count
    }

    func postProcessTiming(_ settings: TimingPostProcessing.Settings, allLines: Bool, sound: [SpeechSpan]) {
        guard isEditable, allLines || !selection.isEmpty else { return }
        let outcome = TimingPostProcessing.processed(allLines ? [] : selection, in: lines, settings: settings, speech: sound)
        guard outcome.lines != lines else { return }
        replace(lines: outcome.lines, selection: selection, actionName: String(localized: "Adjust Timing"))
    }

    var canSplitAtPlayback: Bool {
        guard canEditSelection, let line = activeLine else { return false }
        return line.start < playbackTime && playbackTime < line.end
    }

    /// Splits the active line at the playhead; the text splits at the edit
    /// box's cursor when it has one, else in proportion to the time.
    func splitAtPlayback(atCharacter offset: Int?) {
        guard canSplitAtPlayback, let index = activeIndex else { return }
        apply(SubtitleEditing.split(index, at: playbackTime, atCharacter: offset, in: lines), actionName: String(localized: "Split Line"))
    }

    // MARK: Waveform handles

    /// Shows new times for one line while its handle is dragged; with
    /// `movesNeighbours`, the touching end of the neighbouring line follows.
    func previewTimes(of index: Int, start: AudioTime, end: AudioTime, movesNeighbours: Bool) {
        guard isEditable, lines.indices.contains(index) else { return }
        var preview = lines
        let old = lines[index]
        preview[index].start = min(start, end)
        preview[index].end = max(start, end)
        if movesNeighbours {
            if index > 0, preview[index].start != old.start, lines[index - 1].end == old.start {
                preview[index - 1].end = max(preview[index].start, lines[index - 1].start)
            }
            if index + 1 < lines.count, preview[index].end != old.end, lines[index + 1].start == old.end {
                preview[index + 1].start = min(preview[index].end, lines[index + 1].end)
            }
        }
        setTimingPreview(preview, selection: selection)
    }

    /// Shows the selected lines moved while the active line is dragged.
    func previewShift(by offset: AudioTime) {
        guard isEditable, !selection.isEmpty else { return }
        let outcome = SubtitleEditing.shift(selection, by: offset, changing: .both, in: lines)
        setTimingPreview(outcome.lines, selection: outcome.selection)
    }

    /// Applies the dragged times as one undo step.
    func commitTimingPreview(actionName: String) {
        guard let preview = timingPreview else { return }
        let newSelection = timingPreviewSelection
        cancelTimingPreview()
        guard preview != lines else { return }
        replace(lines: preview, selection: newSelection, actionName: actionName)
    }

    func cancelTimingPreview() {
        setTimingPreview(nil, selection: selection)
    }

    // MARK: Playback ranges

    /// Start and end of what to play; `nil` when there is nothing to play.
    func playbackRange(_ range: PlaybackRange) -> (start: AudioTime, end: AudioTime)? {
        guard let line = activeLine else { return nil }
        let context = Self.playbackContext
        func clampedStart(_ time: AudioTime) -> AudioTime { max(time, .zero) }
        return switch range {
        case .activeLine:
            (line.start, line.end)
        case .selection:
            (selection.map { displayedLines[$0].start }.min() ?? line.start, selection.map { displayedLines[$0].end }.max() ?? line.end)
        case .beforeStart:
            (clampedStart(line.start - context), line.start)
        case .afterStart:
            (line.start, min(line.start + context, line.end))
        case .beforeEnd:
            (clampedStart(max(line.end - context, line.start)), line.end)
        case .afterEnd:
            (line.end, line.end + context)
        }
    }

    /// Selects the next line (for Play Next Line); false at the last line.
    @discardableResult
    func selectNextLine() -> Bool {
        guard let index = activeIndex, index + 1 < lines.count else { return false }
        select([index + 1])
        return true
    }

    @discardableResult
    func selectPreviousLine() -> Bool {
        guard let index = activeIndex, index > 0 else { return false }
        select([index - 1])
        return true
    }
}
