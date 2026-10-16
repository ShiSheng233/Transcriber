import AppKit

/// Every keyboard shortcut, read-only: the menu bar's, read off the menus each
/// time the page appears, then the waveform's own keys. A search field on
/// top narrows the list by command name; the list scrolls under it.
final class ShortcutsSettingsViewController: NSViewController {
    private enum Metrics {
        static let pageHeight: CGFloat = 520
        static let searchSpacing: CGFloat = 12
    }

    private let viewModel: ShortcutsViewModel
    private let mainMenu: () -> NSMenu?
    private var binder: ObservationBinder?

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let sectionStack = NSStackView()
    private let noMatchesLabel = NSTextField(labelWithString: String(localized: "No Matching Shortcuts"))
    private var shownSections: [KeyboardShortcut.Section]?

    init(viewModel: ShortcutsViewModel, title: String, mainMenu: @escaping () -> NSMenu? = { NSApp.mainMenu }) {
        self.viewModel = viewModel
        self.mainMenu = mainMenu
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutsSettingsViewController is created in code")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsForm.pageWidth, height: Metrics.pageHeight))

        searchField.placeholderString = String(localized: "Search Commands")
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = SettingsForm.sectionSpacing
        sectionStack.edgeInsets = NSEdgeInsets(top: 0, left: SettingsForm.pageInset, bottom: SettingsForm.pageInset, right: SettingsForm.pageInset)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sectionStack)

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        noMatchesLabel.textColor = .secondaryLabelColor
        noMatchesLabel.isHidden = true
        noMatchesLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(noMatchesLabel)
        let clipView = scrollView.contentView
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: SettingsForm.pageInset),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsForm.pageInset),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsForm.pageInset),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Metrics.searchSpacing),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // The list is as wide as the visible area, whatever scroller style is in use.
            document.topAnchor.constraint(equalTo: clipView.topAnchor),
            document.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clipView.widthAnchor),
            sectionStack.topAnchor.constraint(equalTo: document.topAnchor),
            sectionStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            sectionStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            sectionStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),

            noMatchesLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            noMatchesLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        view = container
        preferredContentSize = container.frame.size
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        gatherShortcuts()
        binder = ObservationBinder { [weak self] in
            self?.render()
        }
    }

    /// Menu titles change with the app's state, so read them again on each visit.
    override func viewWillAppear() {
        super.viewWillAppear()
        gatherShortcuts()
    }

    private func gatherShortcuts() {
        let menuSections = mainMenu().map(MenuShortcutCollector.sections(in:)) ?? []
        let waveform = KeyboardShortcut.Section(
            title: String(localized: "Waveform"),
            shortcuts: WaveformView.keyboardShortcuts,
            footer: String(localized: "In timing mode, while the waveform has the focus.")
        )
        let grid = KeyboardShortcut.Section(
            title: String(localized: "Subtitle Grid"),
            shortcuts: SubtitleEditorMenu.playbackKeyShortcuts,
            footer: String(localized: "While the subtitle grid has the focus and the file has media.")
        )
        viewModel.showShortcuts(menuSections + [waveform, grid])
    }

    private func render() {
        let sections = viewModel.visibleSections
        noMatchesLabel.isHidden = !sections.isEmpty || viewModel.sections.isEmpty
        guard sections != shownSections else {
            return
        }
        shownSections = sections
        sectionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for section in sections {
            let rows = section.shortcuts.map { SettingsForm.row($0.name, control: ShortcutLabel($0)) }
            let view = SettingsForm.section(section.title, rows: rows, footer: section.footer)
            sectionStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: sectionStack.widthAnchor, constant: -2 * SettingsForm.pageInset).isActive = true
        }
        scrollView.documentView?.scroll(.zero)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        viewModel.search(sender.stringValue)
    }
}

/// Lays the list out from the top, as a scroll view's document should.
private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
