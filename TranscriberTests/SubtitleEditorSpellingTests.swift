import Foundation
import Testing
import TranscriberCore

/// Check Spelling's walk through the file, its corrections as undo steps,
/// and the marks as typed, with a fake checker.
struct SubtitleEditorSpellingTests {
    private let undoManager = UndoManager()
    private let checker = FakeSpellChecker(corrections: ["Starbcks": ["Starbucks"], "teh": ["the", "ten"]])

    private static let lines = [
        TestLines.line(0, 1_000, "今天去 Starbcks 喝咖啡"),
        TestLines.line(2_000, 3_000, "おはよう"),
        TestLines.line(4_000, 5_000, "teh cat and teh dog"),
        TestLines.line(6_000, 7_000, "Starbcks again"),
    ]

    private func makeEditor(selecting index: Int) -> SubtitleEditorViewModel {
        let editor = SubtitleEditorViewModel(spellChecker: checker)
        editor.load(Self.lines, isEditable: true)
        editor.undoManager = undoManager
        editor.select([index])
        return editor
    }

    @Test func walksOnceRoundTheFileFromTheActiveLine() throws {
        let editor = makeEditor(selecting: 1)
        var found: [(line: Int, word: String)] = []
        var misspelling = editor.firstMisspelling()
        while let current = misspelling {
            found.append((current.lineIndex, current.word))
            #expect(editor.selection == [current.lineIndex])
            misspelling = editor.skipMisspelling(current)
        }
        #expect(found.map(\.line) == [2, 2, 3, 0])
        #expect(found.map(\.word) == ["teh", "teh", "Starbcks", "Starbcks"])
        let first = try #require(makeEditor(selecting: 1).firstMisspelling())
        #expect(first.suggestions == ["the", "ten"])
    }

    @Test func aCorrectionIsAnUndoStepAndTheWalkGoesOnAfterIt() throws {
        let editor = makeEditor(selecting: 2)
        let first = try #require(editor.firstMisspelling())
        var second: SubtitleEditorViewModel.Misspelling?
        undoManager.step { second = editor.correctMisspelling(first, to: "the") }
        #expect(editor.lines[2].text == "the cat and teh dog")
        #expect(undoManager.undoActionName == "Correct Spelling")
        let next = try #require(second)
        #expect(next.lineIndex == 2)
        #expect(next.range.lowerBound.utf16Offset(in: next.lineText) == 12)
        undoManager.step { _ = editor.correctMisspelling(next, to: "the") }
        #expect(editor.lines[2].text == "the cat and the dog")
        undoManager.undo()
        #expect(editor.lines[2].text == "the cat and teh dog")
        undoManager.undo()
        #expect(editor.lines == Self.lines)
    }

    @Test func replaceAllCorrectsEveryLineAsOneUndoStep() throws {
        let editor = makeEditor(selecting: 0)
        var reported: [TimedText] = []
        editor.onChange = { reported = $0 }
        let first = try #require(editor.firstMisspelling())
        #expect(first.word == "Starbcks")
        var outcome: (changedLineCount: Int, next: SubtitleEditorViewModel.Misspelling?) = (0, nil)
        undoManager.step { outcome = editor.correctMisspellingEverywhere(first, to: "Starbucks") }
        #expect(outcome.changedLineCount == 2)
        #expect(editor.lines.map(\.text) == ["今天去 Starbucks 喝咖啡", "おはよう", "teh cat and teh dog", "Starbucks again"])
        #expect(reported == editor.lines)
        #expect(outcome.next?.lineIndex == 2)
        undoManager.undo()
        #expect(editor.lines == Self.lines)
    }

    @Test func ignoreAllAndAddToDictionaryGoToTheChecker() throws {
        let editor = makeEditor(selecting: 2)
        let first = try #require(editor.firstMisspelling())
        let afterIgnoring = try #require(editor.ignoreMisspellingEverywhere(first))
        #expect(checker.ignoredWords == ["teh"])
        #expect(afterIgnoring.lineIndex == 3)  // the second "teh" is ignored too
        #expect(editor.learnMisspelling(afterIgnoring) == nil)  // the "Starbcks" in line 0 is learned
        #expect(checker.learnedWords == ["Starbcks"])
        #expect(editor.lines == Self.lines)
    }

    @Test func aLineChangedMeanwhileIsCheckedAgainNotCorrected() throws {
        let editor = makeEditor(selecting: 2)
        let first = try #require(editor.firstMisspelling())
        undoManager.step { editor.setText("dog and teh") }
        let next = try #require(editor.correctMisspelling(first, to: "the"))
        #expect(editor.lines[2].text == "dog and teh")
        #expect(next.lineIndex == 2)
        #expect(next.lineText == "dog and teh")
    }

    @Test func checksOnlyEditableLinesWithAChecker() {
        let readOnly = SubtitleEditorViewModel(spellChecker: checker)
        readOnly.load(Self.lines, isEditable: false)
        #expect(!readOnly.canCheckSpelling)
        #expect(readOnly.firstMisspelling() == nil)
        #expect(!TestLines.editor(Self.lines).canCheckSpelling)
    }

    @Test func marksAsTypedUseTheSubtitleLanguageAndCanBeTurnedOff() {
        let editor = makeEditor(selecting: 0)
        editor.setSpellingLanguage("en")
        #expect(editor.misspelledWords(in: "teh end").count == 1)
        #expect(checker.checkedLanguage == "en")
        #expect(editor.spellingDictionaryName == "English")
        editor.setChecksSpellingWhileTyping(false)
        #expect(editor.misspelledWords(in: "teh end").isEmpty)
    }
}

/// Which language a job's subtitles are spell checked in.
struct SpellingLanguageTests {
    @Test(arguments: [
        ("简体中文", "zh"), ("繁體中文", "zh"), ("English", "en"), ("english (US)", "en"), ("日本語", "ja"),
        ("한국어", "ko"), ("Français", "fr"), ("Brazilian Portuguese", "pt"), ("pt_BR", "pt-BR"), ("de", "de"),
    ])
    func namesAndCodesBecomeLanguageCodes(name: String, code: String) {
        #expect(SpellingLanguage.code(forLanguageName: name) == code)
    }

    @Test func unknownNamesAreLeftToDetection() {
        #expect(SpellingLanguage.code(forLanguageName: "Klingon") == nil)
        #expect(SpellingLanguage.code(forLanguageName: "  ") == nil)
    }

    @Test func aTranscriptIsInTheModelsLanguageUntilTranslated() {
        #expect(SpellingLanguage.ofTranscript(task: .transcribe, languageCode: "ja", llmMode: .translate, translatedInto: nil) == "ja")
        #expect(SpellingLanguage.ofTranscript(task: .transcribe, languageCode: "ja", llmMode: .translate, translatedInto: "English") == "en")
        // ChickenRice: the translate task writes Chinese, which is polished, not translated.
        #expect(SpellingLanguage.ofTranscript(task: .translate, languageCode: "ja", llmMode: .polish, translatedInto: "English") == "zh")
    }

    @Test func subtitleFilesAreInTheTargetLanguageOnlyOnceTranslated() {
        let url = URL(filePath: "/nonexistent/TranscriberTests/film.srt")
        var translation = Job(subtitlesAt: url, mediaURL: nil, lines: TestLines.three)
        #expect(SpellingLanguage.of(translation, targetLanguage: "English") == nil)
        translation.linesBeforeLanguageModel = TestLines.three
        #expect(SpellingLanguage.of(translation, targetLanguage: "English") == "en")
        #expect(SpellingLanguage.of(Job(editing: url, mediaURL: nil, lines: TestLines.three), targetLanguage: "English") == nil)
    }
}
