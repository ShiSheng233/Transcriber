import AVKit
import AppKit

/// Player above, subtitle lines below. Clicking a line seeks to it; playback
/// highlights the current line.
final class JobDetailViewController: NSViewController {
    private let viewModel: JobDetailViewModel
    private let playerView = AVPlayerView()
    private let player = AVPlayer()
    private let tableView = NSTableView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let emptyState = EmptyStateView(
        symbolName: "captions.bubble",
        title: String(localized: "No File Selected"),
        message: String(localized: "Select a file in the list to play it with its subtitles.")
    )
    private let splitView = NSSplitView()
    private var binder: ObservationBinder?
    private var timeObserver: Any?
    private var displayedPlayerURL: URL?
    private var displayedLines: [JobDetailViewModel.Line] = []

    init(viewModel: JobDetailViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("JobDetailViewController is created in code")
    }

    override func loadView() {
        playerView.player = player
        playerView.controlsStyle = .inline
        // No Live Text over video: not needed here, and it runs a background
        // analysis service whose overlay logs Auto Layout conflicts.
        playerView.allowsVideoFrameAnalysis = false

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Time"))
        timeColumn.title = String(localized: "Time")
        timeColumn.width = 170
        timeColumn.resizingMask = []
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Text"))
        textColumn.title = String(localized: "Subtitle")
        textColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(textColumn)
        tableView.usesAutomaticRowHeights = true
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(lineClicked(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(playerView)
        splitView.addArrangedSubview(scrollView)
        splitView.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(splitView)
        container.addSubview(placeholderLabel)
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            // Below the toolbar: the window has a full-size content view.
            splitView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            placeholderLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: 14),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.viewModel.playbackTimeChanged(to: time.seconds)
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func render() {
        if viewModel.playerURL != displayedPlayerURL {
            displayedPlayerURL = viewModel.playerURL
            player.replaceCurrentItem(with: viewModel.playerURL.map { AVPlayerItem(url: $0) })
        }
        playerView.isHidden = !viewModel.showsPlayer
        if viewModel.lines != displayedLines {
            displayedLines = viewModel.lines
            tableView.reloadData()
        }
        emptyState.isHidden = viewModel.hasSelection
        splitView.isHidden = !viewModel.hasSelection
        placeholderLabel.stringValue = viewModel.subtitlesPlaceholder ?? ""
        placeholderLabel.isHidden = !viewModel.hasSelection || viewModel.subtitlesPlaceholder == nil
        highlight(viewModel.currentLineIndex)
    }

    private func highlight(_ index: Int?) {
        guard let index else {
            return
        }
        if tableView.selectedRow != index {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
    }

    @objc private func lineClicked(_ sender: Any?) {
        let index = tableView.clickedRow
        guard displayedLines.indices.contains(index) else {
            return
        }
        player.seek(to: CMTime(seconds: displayedLines[index].startSeconds, preferredTimescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

extension JobDetailViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedLines.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let line = displayedLines[row]
        let isTimeColumn = tableColumn?.identifier.rawValue == "Time"
        let label = NSTextField(wrappingLabelWithString: isTimeColumn ? line.timeText : line.text)
        if isTimeColumn {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        label.isSelectable = false
        return label
    }
}
