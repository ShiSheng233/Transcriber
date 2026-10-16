import Foundation
import Testing
import TranscriberCore

/// The editor's ViewModel without any view: built from the app's sources
/// that do not import AppKit (the test target never launches the app).
/// Text and line commands, and their undo steps.
struct SubtitleEditorViewModelTests {
    private let undoManager = UndoManager()

    @Test func loadsLines() {
        let editor = SubtitleEditorViewModel()
        editor.load([TestLines.line(0, 1_000, "a")], originalLines: [], isEditable: true)
        #expect(editor.rows.count == 1)
    }

    @Test func typingIntoOneLineIsOneUndoStep() {
        let editor = TestLines.editor(undoManager: undoManager)
        editor.select([0])
        undoManager.step { editor.setText("o") }
        undoManager.step { editor.setText("on") }
        undoManager.step { editor.setText("one!") }
        #expect(editor.lines[0].text == "one!")
        undoManager.undo()
        #expect(editor.lines[0].text == "one")
        #expect(!undoManager.canUndo)
    }

    @Test func typingInAnotherLineStartsAnotherUndoStep() {
        let editor = TestLines.editor(undoManager: undoManager)
        editor.select([0])
        undoManager.step { editor.setText("first") }
        editor.select([1])
        undoManager.step { editor.setText("second") }
        undoManager.undo()
        #expect(editor.lines.map(\.text) == ["first", "two", "three"])
    }

    @Test func editedTextIsNoLongerDoubtfulAndIsReported() {
        let editor = TestLines.editor([TestLines.line(0, 1_000, "guess", isDoubtful: true)])
        var reported: [TimedText] = []
        editor.onChange = { reported = $0 }
        #expect(editor.rows[0].isDoubtful)
        editor.select([0])
        editor.setText("checked")
        #expect(!editor.rows[0].isDoubtful)
        #expect(editor.lines[0].confidence == nil)
        #expect(reported.map(\.text) == ["checked"])
    }

    @Test func nothingChangesWhileNotEditable() {
        let editor = SubtitleEditorViewModel()
        editor.load(TestLines.three, isEditable: false)
        editor.select([0])
        editor.setText("changed")
        editor.insertAfter()
        editor.delete()
        #expect(editor.lines == TestLines.three)
        #expect(!editor.canEditSelection)
    }

    @Test func deleteUndoesAndRedoesWithItsSelection() {
        let editor = TestLines.editor(undoManager: undoManager)
        editor.select([1])
        undoManager.step { editor.delete() }
        #expect(editor.lines.map(\.text) == ["one", "three"])
        #expect(editor.selection == [1])
        undoManager.undo()
        #expect(editor.lines == TestLines.three)
        #expect(editor.selection == [1])
        undoManager.redo()
        #expect(editor.lines.map(\.text) == ["one", "three"])
    }

    @Test func insertAfterStartsAtTheLineEndAndStopsAtTheNextLine() {
        let editor = TestLines.editor()
        editor.select([0])
        editor.insertAfter()
        #expect(editor.lines.count == 4)
        #expect(editor.selection == [1])
        #expect(editor.lines[1] == TestLines.line(1_000, 2_000, ""))
    }

    @Test func returnOnTheLastLineMakesANewOne() {
        let editor = TestLines.editor()
        editor.select([1])
        editor.advance()
        #expect(editor.selection == [2])
        editor.advance()
        #expect(editor.lines.count == 4)
        #expect(editor.selection == [3])
        #expect(editor.lines[3].start == AudioTime(milliseconds: 5_000))
    }

    @Test func splitAtTheCursorDividesTheTimeByTheText() {
        let editor = TestLines.editor([TestLines.line(0, 1_000, "abcd")])
        editor.select([0])
        editor.split(atCharacter: 1)
        #expect(editor.lines == [TestLines.line(0, 250, "a"), TestLines.line(250, 1_000, "bcd")])
        #expect(editor.selection == [1])
    }

    @Test func joinSpansTheLinesAndJoinsTheirText() {
        let editor = TestLines.editor()
        editor.select([0])
        #expect(!editor.canMerge)
        editor.select([0, 1])
        editor.merge()
        #expect(editor.lines.map(\.text) == ["one two", "three"])
        #expect(editor.lines[0].end == AudioTime(milliseconds: 3_000))
        #expect(editor.selection == [0])
    }

    @Test func joinKeepingFirstTextDropsTheOthers() {
        let editor = TestLines.editor()
        editor.select([1, 2])
        editor.mergeKeepingFirstText()
        #expect(editor.lines.map(\.text) == ["one", "two"])
        #expect(editor.lines[1].end == AudioTime(milliseconds: 5_000))
    }

    @Test func swapExchangesTextsOfExactlyTwoLines() {
        let editor = TestLines.editor()
        editor.select([0, 1, 2])
        #expect(!editor.canSwap)
        editor.select([0, 2])
        editor.swapTexts()
        #expect(editor.lines.map(\.text) == ["three", "two", "one"])
        #expect(editor.lines.map(\.start) == TestLines.three.map(\.start))
    }

    @Test func sortKeepsTheSameLinesSelected() {
        let editor = TestLines.editor([TestLines.line(4_000, 5_000, "late"), TestLines.line(0, 1_000, "early")])
        editor.select([0])
        #expect(editor.canSort)
        editor.sortByStart()
        #expect(editor.lines.map(\.text) == ["early", "late"])
        #expect(editor.activeLine?.text == "late")
        #expect(!editor.canSort)
    }

    @Test func timeFieldsAcceptOnlyTimes() {
        let editor = TestLines.editor()
        editor.select([1])
        #expect(!editor.setStart("soon"))
        #expect(editor.lines == TestLines.three)
        #expect(editor.setStart("0:00:01.50"))
        #expect(editor.lines[1].start == AudioTime(milliseconds: 1_500))
        // An end before the start takes the start along.
        #expect(editor.setEnd("1"))
        #expect(editor.lines[1].start == AudioTime(milliseconds: 1_000))
        #expect(editor.lines[1].end == AudioTime(milliseconds: 1_000))
    }

    @Test func numbersNoMediaIsThatLongAreNotTimes() {
        let editor = TestLines.editor()
        editor.select([0])
        for text in ["inf", "1e30", "nan", "-1"] {
            #expect(!editor.setEnd(text), "\(text)")
        }
        #expect(editor.lines == TestLines.three)
    }
}
