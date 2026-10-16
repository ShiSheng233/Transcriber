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
}
