import AppKit

/// Accepts dropped files and folders anywhere inside it, outlining itself
/// in the accent color while files are dragged over.
final class FileDropView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    private let highlight = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        highlight.borderWidth = 2
        highlight.cornerRadius = 8
        highlight.isHidden = true
        layer?.addSublayer(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FileDropView is created in code")
    }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    private func fileURLs(in info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(in: sender).isEmpty else {
            return []
        }
        setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlighted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlighted(false)
        let urls = fileURLs(in: sender)
        onDrop(urls)
        return !urls.isEmpty
    }

    private func setHighlighted(_ isHighlighted: Bool) {
        // Resolved now, so the accent color follows the current appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.borderColor = NSColor.controlAccentColor.cgColor
            highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        }
        highlight.isHidden = !isHighlighted
    }
}
