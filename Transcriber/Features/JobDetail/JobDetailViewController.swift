import AVKit
import AppKit

/// Player above, subtitle lines below. Clicking a line seeks to it; playback
/// highlights the current line.
final class JobDetailViewController: NSViewController {
    private let viewModel: JobDetailViewModel
    private let playerView = AVPlayerView()
    private let subtitleOverlay = SubtitleOverlayView()
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
    /// Video needs room for the picture; audio only the control bar.
    private static let audioPlayerHeight: CGFloat = 64
    private lazy var playerMinimumHeight = playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
    private var displayedAsAudio: Bool?
    /// Set when the kind of media changed; applied once the split view has a size.
    private var needsPlayerResize = false

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
        if let overlay = playerView.contentOverlayView {
            subtitleOverlay.frame = overlay.bounds
            subtitleOverlay.autoresizingMask = [.width, .height]
            overlay.addSubview(subtitleOverlay)
        }

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Time"))
        timeColumn.title = String(localized: "Time")
        timeColumn.width = 150
        timeColumn.resizingMask = []
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Text"))
        textColumn.title = String(localized: "Subtitle")
        textColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(textColumn)
        tableView.usesAutomaticRowHeights = true
        tableView.style = .fullWidth
        tableView.intercellSpacing = NSSize(width: 12, height: 6)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(lineClicked(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        splitView.delegate = self
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
            playerMinimumHeight,
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

    override func viewDidLayout() {
        super.viewDidLayout()
        guard needsPlayerResize, splitView.bounds.height > 0, let isAudioOnly = displayedAsAudio else {
            return
        }
        needsPlayerResize = false
        let height = isAudioOnly ? Self.audioPlayerHeight : (splitView.bounds.height * 0.55).rounded()
        splitView.setPosition(height, ofDividerAt: 0)
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
        if playerView.isHidden == viewModel.showsPlayerArea {
            playerView.isHidden = !viewModel.showsPlayerArea
            // A player that was hidden has no height yet: size it when shown.
            if viewModel.showsPlayerArea {
                needsPlayerResize = true
                view.needsLayout = true
            }
        }
        if displayedAsAudio != viewModel.isAudioOnly, viewModel.hasSelection {
            displayedAsAudio = viewModel.isAudioOnly
            playerMinimumHeight.constant = viewModel.isAudioOnly ? Self.audioPlayerHeight : 160
            // When the window resizes, the lower holding priority grows: the
            // picture for video, the subtitle list for audio.
            splitView.setHoldingPriority(viewModel.isAudioOnly ? .defaultHigh : .defaultLow - 1, forSubviewAt: 0)
            splitView.setHoldingPriority(viewModel.isAudioOnly ? .defaultLow - 1 : .defaultLow, forSubviewAt: 1)
            needsPlayerResize = true
            view.needsLayout = true
        }
        if viewModel.lines != displayedLines {
            displayedLines = viewModel.lines
            tableView.reloadData()
        }
        emptyState.isHidden = viewModel.hasSelection
        splitView.isHidden = !viewModel.hasSelection
        placeholderLabel.stringValue = viewModel.subtitlesPlaceholder ?? ""
        placeholderLabel.isHidden = !viewModel.hasSelection || viewModel.subtitlesPlaceholder == nil
        highlight(viewModel.currentLineIndex)
        subtitleOverlay.text = viewModel.isAudioOnly ? nil : viewModel.currentSubtitle
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

extension JobDetailViewController: NSSplitViewDelegate {
    /// The player is shown or hidden only by Hide Player, never collapsed
    /// by the split view (which would hide it behind our back).
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
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
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 1
        }
        label.isSelectable = false
        return label
    }
}
