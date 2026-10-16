import AppKit
import TranscriberCore

/// Window > Activity: the full log, newest at the bottom. It follows new
/// entries while scrolled to the end; scrolling up to read stops that until
/// the end is reached again.
final class ActivityWindowController: NSWindowController {
    private let viewModel: ActivityViewModel
    private let textView = NSTextView()
    private let detailsCheckbox = NSButton(checkboxWithTitle: String(localized: "Show Details"), target: nil, action: nil)
    private var binder: ObservationBinder?
    private var displayedEntryIDs: [UUID] = []
    /// How close to the end still counts as at the end, in points.
    private static let endTolerance: CGFloat = 24

    init(viewModel: ActivityViewModel) {
        self.viewModel = viewModel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Activity")
        window.setFrameAutosaveName("ActivityWindow")
        window.minSize = NSSize(width: 420, height: 240)
        super.init(window: window)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        detailsCheckbox.target = self
        detailsCheckbox.action = #selector(toggleDetails(_:))
        let copyButton = NSButton(title: String(localized: "Copy All"), target: self, action: #selector(copyAll(_:)))
        let clearButton = NSButton(title: String(localized: "Clear"), target: self, action: #selector(clear(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomBar = NSStackView(views: [detailsCheckbox, spacer, clearButton, copyButton])
        bottomBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scrollView)
        content.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ActivityWindowController is created in code")
    }

    private func render() {
        detailsCheckbox.state = viewModel.showsDetails ? .on : .off
        let entries = viewModel.visibleEntries
        let ids = entries.map(\.id)
        guard ids != displayedEntryIDs else {
            return
        }
        let storage = textView.textStorage
        let isAppend = ids.count > displayedEntryIDs.count && Array(ids.prefix(displayedEntryIDs.count)) == displayedEntryIDs
        let followsEnd = isScrolledToEnd
        let newEntries = isAppend ? Array(entries.dropFirst(displayedEntryIDs.count)) : entries
        // One entry per line: a line break before every entry but the first in the view.
        let startsEmpty = !isAppend || displayedEntryIDs.isEmpty
        let text = NSMutableAttributedString()
        for (index, entry) in newEntries.enumerated() {
            let separator = startsEmpty && index == 0 ? "" : "\n"
            text.append(NSAttributedString(string: separator + viewModel.line(for: entry), attributes: attributes(for: entry.level)))
        }
        if isAppend {
            storage?.append(text)
        } else {
            storage?.setAttributedString(text)
        }
        displayedEntryIDs = ids
        if followsEnd {
            scrollToEnd()
        }
    }

    /// Measured from what is visible, before new text is added; a closed
    /// window or a log that fits counts as at the end.
    private var isScrolledToEnd: Bool {
        guard let window, window.isVisible else { return true }
        return textView.visibleRect.maxY >= textView.bounds.maxY - Self.endTolerance
    }

    private func scrollToEnd() {
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.scrollToEndOfDocument(nil)
    }

    /// Opens at the newest entries.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        scrollToEnd()
    }

    private func attributes(for level: LogEntry.Level) -> [NSAttributedString.Key: Any] {
        let color: NSColor = switch level {
        case .info: .labelColor
        case .detail: .secondaryLabelColor
        case .warning: .systemOrange
        case .error: .systemRed
        }
        return [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color]
    }

    @objc private func toggleDetails(_ sender: NSButton) {
        viewModel.setShowsDetails(sender.state == .on)
    }

    @objc private func copyAll(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.logText, forType: .string)
    }

    @objc private func clear(_ sender: Any?) {
        viewModel.clear()
    }
}
