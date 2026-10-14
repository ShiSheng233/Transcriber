import AVKit
import TranscriberCore
import AppKit

/// Player above, the subtitle editor below. Selecting a line seeks to it;
/// the line under the playhead is marked in the grid and shown over the video.
final class JobDetailViewController: NSViewController {
    private let viewModel: JobDetailViewModel
    private let playerView = AVPlayerView()
    private let subtitleOverlay = SubtitleOverlayView()
    private let player = AVPlayer()
    let editorView: SubtitleEditorView
    /// Pauses at the end of the line being played by Play Line.
    private var lineEndObserver: Any?
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
    /// Video needs room for the picture; audio only the control bar.
    private static let audioPlayerHeight: CGFloat = 64
    private lazy var playerMinimumHeight = playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
    private var displayedAsAudio: Bool?
    /// Set when the kind of media changed; applied once the split view has a size.
    private var needsPlayerResize = false

    init(viewModel: JobDetailViewModel) {
        self.viewModel = viewModel
        editorView = SubtitleEditorView(viewModel: viewModel.editor)
        super.init(nibName: nil, bundle: nil)
        editorView.onUserSelectedLine = { [weak self] index in
            self?.seekToLine(index)
        }
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

        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        splitView.delegate = self
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(playerView)
        splitView.addArrangedSubview(editorView)
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
            editorView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            placeholderLabel.centerXAnchor.constraint(equalTo: editorView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: editorView.centerYAnchor, constant: -40),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualTo: editorView.widthAnchor, constant: -40),
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
        emptyState.isHidden = viewModel.hasSelection
        splitView.isHidden = !viewModel.hasSelection
        placeholderLabel.stringValue = viewModel.subtitlesPlaceholder ?? ""
        placeholderLabel.isHidden = !viewModel.hasSelection || viewModel.subtitlesPlaceholder == nil
        subtitleOverlay.text = viewModel.isAudioOnly ? nil : viewModel.currentSubtitle
    }

    // MARK: Playback commands

    func seekToLine(_ index: Int) {
        guard viewModel.editor.lines.indices.contains(index) else { return }
        seek(to: viewModel.editor.lines[index].start.seconds)
    }

    /// Plays the active line from its start and pauses at its end.
    func playActiveLine() {
        guard let line = viewModel.editor.activeLine, player.currentItem != nil else { return }
        if let lineEndObserver {
            player.removeTimeObserver(lineEndObserver)
        }
        let end = CMTime(seconds: line.end.seconds, preferredTimescale: 1_000)
        lineEndObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.player.pause()
            }
        }
        player.seek(to: CMTime(seconds: line.start.seconds, preferredTimescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.play()
            }
        }
    }

    func jumpToActiveLine(end: Bool) {
        guard let line = viewModel.editor.activeLine else { return }
        player.pause()
        seek(to: (end ? line.end : line.start).seconds)
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero)
        viewModel.playbackTimeChanged(to: seconds)
    }
}

extension JobDetailViewController: NSSplitViewDelegate {
    /// The player is shown or hidden only by Hide Player, never collapsed
    /// by the split view (which would hide it behind our back).
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}
