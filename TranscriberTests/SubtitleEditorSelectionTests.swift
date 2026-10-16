import Foundation
import Testing
import TranscriberCore

/// Select Lines, Find and Replace, the original text, and lines that come
/// back from the queue (a running job, retranslation, retranscription).
struct SubtitleEditorSelectionTests {
    private let undoManager = UndoManager()

    private static let mixed = [
        TestLines.line(0, 1_000, "hello", isDoubtful: true),
        TestLines.line(2_000, 2_100, " "),
        TestLines.line(3_000, 4_000, "Hello world", isDoubtful: false),
    ]

    @Test func criteriaCombineByAllOrAny() {
        let editor = TestLines.editor(Self.mixed)
        let hello = SubtitleEditorViewModel.LineCriterion.text("hello", .init())
        #expect(editor.lines(matching: [hello], requiresAll: true) == [0, 2])
        #expect(editor.lines(matching: [hello, .doubtful], requiresAll: true) == [0])
        #expect(editor.lines(matching: [.emptyText, .doubtful], requiresAll: false) == [0, 1])
        #expect(editor.lines(matching: [.durationBelow(AudioTime(milliseconds: 200))], requiresAll: true) == [1])
        #expect(editor.lines(matching: [], requiresAll: true).isEmpty)
    }

    @Test func aPatternThatCannotMatchIsLeftOutRatherThanMatchingNothing() {
        let editor = TestLines.editor(Self.mixed)
        let broken = SubtitleEditorViewModel.LineCriterion.text("(", .init(usesRegularExpression: true))
        #expect(editor.lines(matching: [broken, .doubtful], requiresAll: true) == [0])
    }

    @Test func matchesCombineWithTheSelection() {
        let editor = TestLines.editor()
        editor.select([0])
        editor.select([2], mode: .add)
        #expect(editor.selection == [0, 2])
        editor.select([0, 1], mode: .subtract)
        #expect(editor.selection == [2])
        editor.select([1], mode: .replace)
        #expect(editor.selection == [1])
    }

    @Test func findNextWrapsAroundFromTheActiveLine() {
        let editor = TestLines.editor()
        editor.select([2])
        #expect(editor.findNext("ONE", options: .init()))
        #expect(editor.selection == [0])
        #expect(!editor.findNext("ONE", options: .init(matchesCase: true)))
        #expect(editor.selection == [0])
    }

    @Test func replaceAllCountsChangedLinesInOneUndoStep() {
        let editor = TestLines.editor(undoManager: undoManager)
        var count = 0
        undoManager.step { count = editor.replaceAll("t(\\w)", with: "T$1", options: .init(usesRegularExpression: true)) }
        #expect(count == 2)
        #expect(editor.lines.map(\.text) == ["one", "Two", "Three"])
        undoManager.undo()
        #expect(editor.lines == TestLines.three)
        // Without regular expressions, "$1" is literal text.
        undoManager.step { editor.replaceAll("one", with: "$1", options: .init()) }
        #expect(editor.lines[0].text == "$1")
    }

    @Test func originalsFollowTheLinesThroughAJoin() {
        let originals = [TestLines.line(0, 1_000, "いち"), TestLines.line(2_000, 3_000, "に"), TestLines.line(4_000, 5_000, "さん")]
        let editor = TestLines.editor(originals: originals)
        #expect(editor.showsSourceColumn)
        #expect(editor.rows.map(\.source) == ["いち", "に", "さん"])
        editor.select([0, 1])
        editor.merge()
        #expect(editor.activeSource == "いち\nに")
        #expect(editor.rows[0].source == "いち ⏎ に")
        editor.insertAfter()
        #expect(editor.rows[1].source.isEmpty)
    }

    @Test func theOriginalColumnNeedsOriginalsAndThePreference() {
        let editor = TestLines.editor()
        #expect(!editor.showsSourceColumn)
        #expect(editor.activeSource == nil)
        editor.load(TestLines.three, originalLines: TestLines.three, isEditable: true)
        editor.setPrefersSourceColumn(false)
        #expect(editor.hasSources)
        #expect(!editor.showsSourceColumn)
    }

    @Test func aRunningJobsLinesAreFollowedUntilTheEditorOwnsThem() {
        let editor = SubtitleEditorViewModel()
        editor.load(Array(TestLines.three.prefix(1)), isEditable: false)
        editor.follow(TestLines.three, isEditable: false)
        #expect(editor.lines == TestLines.three)
        editor.follow(TestLines.three, isEditable: true)
        editor.select([0])
        editor.setText("edited")
        // A stale snapshot from the queue does not undo the edit.
        editor.follow(TestLines.three, isEditable: true)
        #expect(editor.lines[0].text == "edited")
    }

    @Test func retranslationLeavesLinesRetimedMeanwhileAlone() {
        let editor = TestLines.editor()
        let sent = TestLines.three
        editor.select([1])
        editor.setStart("2.5")
        var answered = sent
        answered[0].text = "uno"
        answered[1].text = "dos"
        editor.applyRetranslation(answered, sentLines: sent)
        #expect(editor.lines.map(\.text) == ["uno", "two", "three"])
    }

    @Test func retranscriptionIsRefusedOnceTheLinesChanged() {
        let editor = TestLines.editor()
        let sent = TestLines.three
        let newLines = [TestLines.line(0, 1_000, "one"), TestLines.line(1_500, 2_500, "new"), TestLines.line(4_000, 5_000, "three")]
        editor.select([2])
        editor.setText("changed")
        #expect(!editor.applyRetranscription(newLines, sentLines: sent, newLineIndices: [1]))
        editor.setText("three")
        #expect(editor.applyRetranscription(newLines, sentLines: sent, newLineIndices: [1]))
        #expect(editor.lines == newLines)
        #expect(editor.selection == [1])
    }
}
