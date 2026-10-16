import Foundation
import TranscriberCore

/// Short ways to write subtitle lines and editors in tests.
enum TestLines {
    static func line(_ startMilliseconds: Int, _ endMilliseconds: Int, _ text: String, isDoubtful: Bool? = nil) -> TimedText {
        TimedText(
            start: AudioTime(milliseconds: startMilliseconds),
            end: AudioTime(milliseconds: endMilliseconds),
            text: text,
            confidence: isDoubtful.map {
                RecognitionConfidence(averageLogProbability: -0.5, noSpeechProbability: 0.1, compressionRatio: 1.5, isDoubtful: $0)
            }
        )
    }

    /// Three lines a second apart, each a second long.
    static let three = [line(0, 1_000, "one"), line(2_000, 3_000, "two"), line(4_000, 5_000, "three")]

    /// An editable editor holding `lines`. The caller keeps `undoManager`
    /// alive: the editor holds it weakly, as it holds the window's.
    static func editor(_ lines: [TimedText] = three, originals: [TimedText] = [], undoManager: UndoManager? = nil) -> SubtitleEditorViewModel {
        let editor = SubtitleEditorViewModel()
        editor.load(lines, originalLines: originals, isEditable: true)
        editor.undoManager = undoManager
        return editor
    }
}
