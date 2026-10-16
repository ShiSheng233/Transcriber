import Foundation
import Testing
import TranscriberCore

/// The editor's ViewModel without any view: built from the app's sources
/// that do not import AppKit (the test target never launches the app).
struct SubtitleEditorViewModelTests {
    private static func line(_ start: Double, _ text: String) -> TimedText {
        TimedText(start: AudioTime(seconds: start), end: AudioTime(seconds: start + 1), text: text)
    }

    @Test func loadsLines() {
        let editor = SubtitleEditorViewModel()
        editor.load([TimedText(start: .zero, end: AudioTime(seconds: 1), text: "a")], originalLines: [], isEditable: true)
        #expect(editor.rows.count == 1)
    }

    @Test func proofreadingIsOneUndoStepAndSkipsLinesChangedMeanwhile() {
        let editor = SubtitleEditorViewModel()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        editor.undoManager = undoManager
        let sent = [Self.line(0, "ゆいちゃん"), Self.line(2, "おはよう"), Self.line(4, "またね")]
        editor.load(sent, isEditable: true)
        editor.select([2])
        // Without an event loop, each step is grouped by hand.
        func step(_ change: () -> Void) {
            undoManager.beginUndoGrouping()
            change()
            undoManager.endUndoGrouping()
        }
        step { editor.setStart("0:00:04.50") }  // retimed while the request ran

        var corrected = sent
        corrected[0].text = "結衣ちゃん"
        corrected[2].text = "又ね"
        step { editor.applyProofreading(corrected, sentLines: sent) }

        #expect(editor.lines.map(\.text) == ["結衣ちゃん", "おはよう", "またね"])
        #expect(undoManager.undoActionName == "Proofread")
        undoManager.undo()
        #expect(editor.lines[0].text == "ゆいちゃん")
    }

    @Test func unifiesTheChosenSpellingsAsOneUndoStep() throws {
        let editor = SubtitleEditorViewModel()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        editor.undoManager = undoManager
        let original = [Self.line(0, "ナナミ、来て"), Self.line(2, "ななみ、待って"), Self.line(4, "ﾅﾅﾐちゃん"), Self.line(6, "おはよう")]
        editor.load(original, isEditable: true)
        var reported: [TimedText] = []
        editor.onChange = { reported = $0 }

        let group = try #require(editor.termVariantGroups(glossaryTerms: []).first)
        #expect(group.suggestedSpelling == "ナナミ")
        undoManager.beginUndoGrouping()
        let changed = editor.unifySpellings([group.key: group.suggestedSpelling])
        undoManager.endUndoGrouping()

        #expect(changed == 2)
        #expect(editor.lines.map(\.text) == ["ナナミ、来て", "ナナミ、待って", "ナナミちゃん", "おはよう"])
        #expect(reported == editor.lines)
        #expect(editor.termVariantGroups(glossaryTerms: []).isEmpty)
        #expect(undoManager.undoActionName == "Unify Spellings")
        undoManager.undo()
        #expect(editor.lines == original)
    }

    @Test func aGlossaryTermKeepsTheGlossarySpelling() {
        let editor = SubtitleEditorViewModel()
        editor.load([Self.line(0, "ｱﾘｽだよ")], isEditable: true)
        let groups = editor.termVariantGroups(glossaryTerms: ["アリス", "爱丽丝"])
        #expect(groups.map(\.suggestedSpelling) == ["アリス"])
    }
}
