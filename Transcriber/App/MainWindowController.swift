import AppKit

final class MainWindowController: NSWindowController {
    private static let initialContentSize = NSSize(width: 960, height: 600)

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcriber"
        window.setFrameAutosaveName("MainWindow")
        window.contentViewController = JobQueueViewController()
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code")
    }
}
