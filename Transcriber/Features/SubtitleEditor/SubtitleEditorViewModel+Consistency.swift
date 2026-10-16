import Foundation
import TranscriberCore

/// Check Consistency: names and terms written in more than one way, and
/// unifying the chosen ones (see `TermVariants`).
extension SubtitleEditorViewModel {
    /// The file's terms with more than one spelling, most frequent first.
    /// - Parameter glossaryTerms: both sides of the glossary's entries,
    ///   whose spelling is the one to keep.
    func termVariantGroups(glossaryTerms: [String]) -> [TermVariants.Group] {
        TermVariants.groups(in: lines.map(\.text), glossaryTerms: glossaryTerms)
    }

    /// Writes every chosen term the one way given, as one undo step.
    /// - Parameter spellings: the spelling to keep by group key.
    /// - Returns: how many lines changed.
    @discardableResult
    func unifySpellings(_ spellings: [String: String]) -> Int {
        guard isEditable, !spellings.isEmpty else { return 0 }
        let texts = TermVariants.unifying(lines.map(\.text), to: spellings)
        var updated = lines
        var changed = 0
        for index in updated.indices where updated[index].text != texts[index] {
            updated[index].text = texts[index]
            changed += 1
        }
        if changed > 0 {
            replace(lines: updated, selection: selection, actionName: String(localized: "Unify Spellings"))
        }
        return changed
    }
}
