import Foundation
import Testing
import TranscriberCore

/// The editor's ViewModel without any view: built from the app's sources
/// that do not import AppKit (the test target never launches the app).
struct SubtitleEditorViewModelTests {
    @Test func loadsLines() {
        let editor = SubtitleEditorViewModel()
        editor.load([TimedText(start: .zero, end: AudioTime(seconds: 1), text: "a")], originalLines: [], isEditable: true)
        #expect(editor.rows.count == 1)
    }
}
