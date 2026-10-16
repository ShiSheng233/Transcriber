import AppKit

/// The editor's grid. While it has focus the waveform's playback keys
/// (Space, Q/E/D/W, S) run the same commands as the menu, so lines can be
/// checked by ear without leaving the grid; the edit box and the time
/// fields are their own responders and keep their keys for typing. The
/// arrow keys stay the table's: they move the selection, which seeks.
final class SubtitleGridTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              event.specialKey == nil,
              let action = event.charactersIgnoringModifiers.flatMap(SubtitleEditorMenu.playbackKeyAction(for:))
        else {
            super.keyDown(with: event)
            return
        }
        NSApp.sendAction(action, to: nil, from: self)
    }
}
