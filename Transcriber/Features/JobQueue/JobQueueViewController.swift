import AppKit

/// The list of queued files. Accepts dropped files and folders.
final class JobQueueViewController: NSViewController {
    private let viewModel: JobQueueViewModel
    private let statusBar: ActivityStatusBar
    private let tableView = NSTableView()
    private let emptyState = EmptyStateView(
        symbolName: "waveform.badge.plus",
        title: String(localized: "No Files"),
        message: String(localized: "Drop audio or video files or folders here, or click + to add them.")
    )
    private var binder: ObservationBinder?
    private var displayedRows: [JobQueueViewModel.Row] = []

    init(viewModel: JobQueueViewModel, activityViewModel: ActivityViewModel, showActivity: @escaping () -> Void) {
        self.viewModel = viewModel
        statusBar = ActivityStatusBar(viewModel: activityViewModel, showLog: showActivity)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("JobQueueViewController is created in code")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Job"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([.fileURL])
        tableView.menu = makeContextMenu()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(emptyState)
        container.addSubview(statusBar)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: container.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    private func render() {
        let rows = viewModel.rows
        let selectedID = viewModel.selectedJobID
        emptyState.isHidden = !rows.isEmpty
        guard rows != displayedRows else {
            return
        }
        let sameJobs = rows.map(\.id) == displayedRows.map(\.id)
        displayedRows = rows
        if sameJobs {
            // Only statuses changed: refresh cells in place to keep selection and scrolling.
            for (index, row) in rows.enumerated() {
                (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? JobCellView)?.configure(with: row)
            }
        } else {
            tableView.reloadData()
            if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
                tableView.selectRowIndexes([index], byExtendingSelection: false)
            }
        }
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Show Subtitles in Finder"), action: #selector(showOutputsInFinder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Show Source in Finder"), action: #selector(showSourceInFinder(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Cancel"), action: #selector(cancelJob(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Remove from List"), action: #selector(removeJob(_:)), keyEquivalent: "")
        return menu
    }

    private var clickedJob: (row: JobQueueViewModel.Row, index: Int)? {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard displayedRows.indices.contains(index) else {
            return nil
        }
        return (displayedRows[index], index)
    }

    @objc private func showOutputsInFinder(_ sender: Any?) {
        if let row = clickedJob?.row {
            NSWorkspace.shared.activateFileViewerSelecting(row.outputURLs)
        }
    }

    @objc private func showSourceInFinder(_ sender: Any?) {
        if let row = clickedJob?.row {
            NSWorkspace.shared.activateFileViewerSelecting([row.sourceURL])
        }
    }

    @objc private func cancelJob(_ sender: Any?) {
        if let row = clickedJob?.row {
            viewModel.cancel(jobID: row.id)
        }
    }

    @objc private func removeJob(_ sender: Any?) {
        if let row = clickedJob?.row {
            viewModel.remove(jobID: row.id)
        }
    }
}

extension JobQueueViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let row = clickedJob?.row else {
            return false
        }
        switch menuItem.action {
        case #selector(showOutputsInFinder(_:)): return !row.outputURLs.isEmpty
        case #selector(cancelJob(_:)): return row.canCancel
        default: return true
        }
    }
}

extension JobQueueViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: JobCellView.identifier, owner: self) as? JobCellView ?? JobCellView()
        cell.configure(with: displayedRows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = tableView.selectedRow
        viewModel.select(jobID: displayedRows.indices.contains(index) ? displayedRows[index].id : nil)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        viewModel.addFiles(urls)
        return !urls.isEmpty
    }
}
