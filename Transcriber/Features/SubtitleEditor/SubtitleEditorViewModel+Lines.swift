import Foundation
import TranscriberCore

/// Line commands beyond the basic ones, and Select Lines.
extension SubtitleEditorViewModel {
    var canSwap: Bool {
        isEditable && selection.count == 2
    }

    var canSort: Bool {
        isEditable && !SubtitleEditing.isSortedByStart(lines)
    }

    func mergeKeepingFirstText() {
        guard canMerge else { return }
        apply(SubtitleEditing.mergeKeepingFirstText(selection, in: lines), actionName: String(localized: "Join Lines"))
    }

    func swapTexts() {
        guard canSwap else { return }
        apply(SubtitleEditing.swapTexts(selection, in: lines), actionName: String(localized: "Swap Lines"))
    }

    func sortByStart() {
        guard canSort else { return }
        apply(SubtitleEditing.sortedByStart(lines, keeping: selection), actionName: String(localized: "Sort Lines"))
    }

    /// What Select Lines looks for.
    enum LineCriterion: Equatable {
        case text(String, SearchOptions)
        case readingSpeedAbove(Double)
        case durationBelow(AudioTime)
        case durationAbove(AudioTime)
        case overlapping
        case emptyText
    }

    /// The lines meeting every criterion (`requiresAll`) or any of them.
    func lines(matching criteria: [LineCriterion], requiresAll: Bool) -> [Int] {
        let sets = criteria.compactMap { matches(of: $0).map(Set.init) }
        guard let first = sets.first else { return [] }
        let combined = sets.dropFirst().reduce(first) { requiresAll ? $0.intersection($1) : $0.union($1) }
        return combined.sorted()
    }

    /// Combines `matches` with the selection. Not an undo step.
    func select(_ matches: [Int], mode: SubtitleSelection.Mode) {
        select(SubtitleSelection.combined(matches, with: selection, mode: mode))
    }

    /// `nil` for a criterion that cannot match (an empty or invalid pattern).
    private func matches(of criterion: LineCriterion) -> [Int]? {
        let coreCriterion: SubtitleSelection.Criterion
        switch criterion {
        case .text(let query, let options):
            guard let pattern = Self.pattern(for: query, options: options) else { return nil }
            coreCriterion = .textMatching { text in
                pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        case .readingSpeedAbove(let limit):
            coreCriterion = .readingSpeedAbove(limit)
        case .durationBelow(let duration):
            coreCriterion = .durationBelow(duration)
        case .durationAbove(let duration):
            coreCriterion = .durationAbove(duration)
        case .overlapping:
            coreCriterion = .overlapping
        case .emptyText:
            coreCriterion = .textMatching { $0.allSatisfy(\.isWhitespace) }
        }
        return SubtitleSelection.matching(coreCriterion, in: lines)
    }
}
