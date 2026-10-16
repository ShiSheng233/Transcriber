import Foundation
import Observation
import TranscriberCore

/// An Aegisub-style editor over one job's subtitles: a grid of lines, the
/// selected line's times and text, and commands that each make one undo step.
///
/// While a job runs, the lines follow it (translations appear batch by
/// batch) and nothing can be edited. Once it is done the editor holds the
/// lines; every change is reported through `onChange` so the queue keeps it.
@Observable
final class SubtitleEditorViewModel {
    struct Row: Equatable {
        let number: Int
        let start: String
        let end: String
        let duration: String
        let charactersPerSecond: String
        /// 0 up to 15 CPS, rising to 1 at 30: how red the CPS cell is (Aegisub).
        let readingSpeedWarning: Double
        let text: String
        let isPlaying: Bool
        /// Overlaps the active line in time (Aegisub shows it in red).
        let overlapsActiveLine: Bool
    }

    /// Aegisub `Subtitle/Character Counter/CPS Warning Threshold` and `Error Threshold`.
    private static let readingSpeedWarning = 15.0
    private static let readingSpeedError = 30.0
    /// Typing into one line within this long is one undo step (Aegisub).
    private static let typingUndoWindow: TimeInterval = 30

    private(set) var lines: [TimedText] = []
    /// Sorted line indices.
    private(set) var selection: [Int] = []
    private(set) var isEditable = false
    /// The line under the playhead.
    private(set) var playingIndex: Int?
    private(set) var playbackTime = AudioTime.zero

    /// The cursor is in the edit box: playback must not change the line.
    @ObservationIgnored var isEditingInEditBox = false

    /// The window's undo manager; set by the view.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Edited lines, for the queue to keep.
    @ObservationIgnored var onChange: ([TimedText]) -> Void = { _ in }

    @ObservationIgnored private var lastTyping: (index: Int, date: Date)?

    var rows: [Row] {
        let overlaps = activeIndex.map { SubtitleEditing.overlapping($0, in: lines) } ?? []
        return lines.enumerated().map { index, line in
            let speed = SubtitleEditing.charactersPerSecond(line)
            let warning = speed.map { speed in
                speed <= Self.readingSpeedWarning ? 0
                    : min((speed - Self.readingSpeedWarning + 1) / (Self.readingSpeedError - Self.readingSpeedWarning + 1), 1)
            } ?? 0
            return Row(
                number: index + 1,
                start: SubtitleTimeFormat.string(line.start),
                end: SubtitleTimeFormat.string(line.end),
                duration: SubtitleTimeFormat.string(line.end - line.start),
                charactersPerSecond: speed.map { String(Int($0.rounded())) } ?? "",
                readingSpeedWarning: warning,
                // The grid shows breaks as Aegisub does; the edit box has the real text.
                text: line.text.replacingOccurrences(of: "\n", with: " ⏎ "),
                isPlaying: index == playingIndex,
                overlapsActiveLine: overlaps.contains(index)
            )
        }
    }

    /// "12/40": the active line's longest line against Aegisub's limit.
    var characterCount: (count: Int, limit: Int)? {
        activeLine.map { (SubtitleEditing.longestLineLength($0.text), SubtitleEditing.characterLimit) }
    }

    /// The line the edit box shows: the first selected one.
    var activeIndex: Int? {
        selection.first
    }

    var activeLine: TimedText? {
        activeIndex.map { lines[$0] }
    }

    var activeDuration: String {
        activeLine.map { SubtitleTimeFormat.string($0.end - $0.start) } ?? ""
    }

    var canEditSelection: Bool {
        isEditable && !selection.isEmpty
    }

    var canMerge: Bool {
        isEditable && selection.count >= 2
    }

    // MARK: Loading and playback

    /// A different job: its lines, no selection, no undo history.
    func load(_ newLines: [TimedText], isEditable: Bool) {
        undoManager?.removeAllActions(withTarget: self)
        lines = newLines
        selection = []
        playingIndex = nil
        self.isEditable = isEditable
    }

    /// The same job changed in the queue. A running job's lines follow it;
    /// once editable, the editor's own lines win (a snapshot may be stale).
    func follow(_ newLines: [TimedText], isEditable editable: Bool) {
        if !isEditable, newLines != lines {
            lines = newLines
            selection = selection.filter(newLines.indices.contains)
        }
        isEditable = editable
    }

    /// While playing, the grid follows: the line being spoken becomes the
    /// selected one (unless the user is typing in the edit box).
    func playbackTimeChanged(to time: AudioTime, isPlaying: Bool) {
        playbackTime = time
        let index = lines.firstIndex { time >= $0.start && time < $0.end }
        if index != playingIndex {
            playingIndex = index
            if isPlaying, let index, !isEditingInEditBox, selection != [index] {
                select([index])
            }
        }
    }

    // MARK: Intents

    func select(_ indices: [Int]) {
        let valid = indices.filter(lines.indices.contains).sorted()
        if valid != selection {
            selection = valid
            lastTyping = nil
        }
    }

    /// The edit box's text for the active line, as it is typed. Typing in
    /// one line is one undo step until 30 s pass or another line is edited.
    func setText(_ text: String) {
        guard isEditable, let index = activeIndex, lines[index].text != text else {
            return
        }
        let outcome = SubtitleEditing.setText(index, to: text, in: lines)
        if let lastTyping, lastTyping.index == index, Date().timeIntervalSince(lastTyping.date) < Self.typingUndoWindow {
            lines = outcome.lines  // part of the current undo step
            onChange(lines)
        } else {
            apply(outcome, actionName: String(localized: "Edit Text"), keepsSelection: true)
            lastTyping = (index, Date())
        }
    }

    /// Aegisub's Enter: go to the next line, or make one after the last.
    func advance() {
        guard let index = activeIndex else { return }
        lastTyping = nil
        if index + 1 < lines.count {
            select([index + 1])
        } else if isEditable {
            insertAfter()
        }
    }

    func makeContinuous(changing edge: SubtitleEditing.ContinuousEdge) {
        guard canEditSelection else { return }
        apply(SubtitleEditing.makeContinuous(selection, changing: edge, in: lines), actionName: String(localized: "Make Times Continuous"))
    }

    /// Aegisub "Shift to current frame": moves the selection so the active
    /// line starts at the playhead.
    func shiftToPlayback() {
        guard canEditSelection, let line = activeLine else { return }
        let offset = playbackTime.milliseconds - line.start.milliseconds
        guard offset != 0 else { return }
        apply(SubtitleEditing.shift(selection, by: offset, in: lines), actionName: String(localized: "Shift Times"))
    }

    // MARK: Find and replace

    struct SearchOptions: Equatable {
        var matchesCase = false
        var usesRegularExpression = false
    }

    /// Selects the next line after the active one whose text matches;
    /// false when no line does.
    @discardableResult
    func findNext(_ query: String, options: SearchOptions) -> Bool {
        guard let pattern = Self.pattern(for: query, options: options), !lines.isEmpty else {
            return false
        }
        let start = (activeIndex ?? -1) + 1
        for offset in 0..<lines.count {
            let index = (start + offset) % lines.count
            let text = lines[index].text
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                select([index])
                return true
            }
        }
        return false
    }

    /// Replaces every match in every line; returns how many lines changed.
    @discardableResult
    func replaceAll(_ query: String, with replacement: String, options: SearchOptions) -> Int {
        guard isEditable, let pattern = Self.pattern(for: query, options: options) else {
            return 0
        }
        let template = options.usesRegularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        var changed = 0
        let newLines = lines.map { line -> TimedText in
            let text = pattern.stringByReplacingMatches(in: line.text, range: NSRange(line.text.startIndex..., in: line.text), withTemplate: template)
            if text != line.text {
                changed += 1
            }
            return TimedText(start: line.start, end: line.end, text: text)
        }
        if changed > 0 {
            replace(lines: newLines, selection: selection, actionName: String(localized: "Replace All"))
        }
        return changed
    }

    private static func pattern(for query: String, options: SearchOptions) -> NSRegularExpression? {
        guard !query.isEmpty else {
            return nil
        }
        let source = options.usesRegularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        return try? NSRegularExpression(pattern: source, options: options.matchesCase ? [] : [.caseInsensitive])
    }

    /// Returns false for text that is not a time.
    @discardableResult
    func setStart(_ text: String) -> Bool {
        guard let time = SubtitleTimeFormat.time(from: text) else {
            return false
        }
        setTimes(start: time)
        return true
    }

    @discardableResult
    func setEnd(_ text: String) -> Bool {
        guard let time = SubtitleTimeFormat.time(from: text) else {
            return false
        }
        setTimes(end: time)
        return true
    }

    func setStartToPlayback() {
        setTimes(start: playbackTime)
    }

    func setEndToPlayback() {
        setTimes(end: playbackTime)
    }

    func insertBefore() {
        guard isEditable else { return }
        apply(SubtitleEditing.insert(before: activeIndex ?? 0, in: lines), actionName: String(localized: "Insert Line"))
    }

    func insertAfter() {
        guard isEditable else { return }
        apply(SubtitleEditing.insert(after: selection.last ?? lines.count - 1, in: lines), actionName: String(localized: "Insert Line"))
    }

    func duplicate() {
        guard canEditSelection else { return }
        apply(SubtitleEditing.duplicate(selection, in: lines), actionName: String(localized: "Duplicate Lines"))
    }

    func delete() {
        guard canEditSelection else { return }
        apply(SubtitleEditing.delete(selection, in: lines), actionName: String(localized: "Delete Lines"))
    }

    func merge() {
        guard canMerge else { return }
        apply(SubtitleEditing.merge(selection, in: lines), actionName: String(localized: "Join Lines"))
    }

    /// Splits the active line where the edit box's cursor is.
    func split(atCharacter offset: Int) {
        guard isEditable, let index = activeIndex else { return }
        apply(SubtitleEditing.split(index, atCharacter: offset, in: lines), actionName: String(localized: "Split Line"))
    }

    /// The selected lines, or all of them when none is selected.
    func shift(byMilliseconds offset: Int) {
        guard isEditable, offset != 0 else { return }
        apply(SubtitleEditing.shift(selection, by: offset, in: lines), actionName: String(localized: "Shift Times"), keepsSelection: selection.isEmpty)
    }

    /// New text for lines that were sent to the language model, as one undo
    /// step. A line changed meanwhile (other times, or deleted) is left alone.
    /// - Parameters:
    ///   - sentLines: the lines as they were when the request was made.
    ///   - newLines: the same lines with the answered ones replaced.
    func applyRetranslation(_ newLines: [TimedText], sentLines: [TimedText]) {
        guard isEditable, newLines.count == sentLines.count else { return }
        var updated = lines
        for index in newLines.indices where newLines[index] != sentLines[index] && updated.indices.contains(index) {
            let current = updated[index]
            if current.start == sentLines[index].start, current.end == sentLines[index].end {
                updated[index].text = newLines[index].text
            }
        }
        guard updated != lines else { return }
        replace(lines: updated, selection: selection, actionName: String(localized: "Retranslate"))
    }

    /// The lines with a stretch transcribed again, as one undo step; the
    /// new lines are selected. Nothing happens if the lines changed since
    /// the request (returns false).
    @discardableResult
    func applyRetranscription(_ newLines: [TimedText], sentLines: [TimedText], newLineIndices: [Int]) -> Bool {
        guard isEditable, lines == sentLines else { return false }
        replace(lines: newLines, selection: newLineIndices, actionName: String(localized: "Retranscribe"))
        return true
    }

    // MARK: Private

    private func setTimes(start: AudioTime? = nil, end: AudioTime? = nil) {
        guard isEditable, let index = activeIndex else { return }
        let outcome = SubtitleEditing.setTimes(index, start: start, end: end, in: lines)
        guard outcome.lines != lines else { return }
        apply(outcome, actionName: String(localized: "Change Times"), keepsSelection: true)
    }

    private func apply(_ outcome: SubtitleEditing.Outcome, actionName: String, keepsSelection: Bool = false) {
        replace(lines: outcome.lines, selection: keepsSelection ? selection : outcome.selection, actionName: actionName)
    }

    /// One undo step; undoing registers the redo the same way.
    private func replace(lines newLines: [TimedText], selection newSelection: [Int], actionName: String) {
        lastTyping = nil
        let previousLines = lines
        let previousSelection = selection
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.replace(lines: previousLines, selection: previousSelection, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        lines = newLines
        selection = newSelection.filter(newLines.indices.contains)
        onChange(newLines)
    }
}
