import AudioOverview
import Foundation
import Observation
import TranscriberCore

/// The selected job: its media for the player, and its subtitles in the
/// editor (editable once the job is done).
@Observable
final class JobDetailViewModel {
    private static let showsPlayerKey = "ShowsPlayer"
    private static let timingModeKey = "ShowsTimingMode"
    private static let sourceColumnKey = "ShowsSourceColumn"
    private static let audioExtensions: Set<String> = ["mp3", "wav", "flac", "m4a", "aac", "ogg", "opus", "wma"]
    private let userDefaults: UserDefaults

    let editor = SubtitleEditorViewModel()
    let waveform: WaveformViewModel
    private(set) var mediaURL: URL?
    /// Off: only the subtitles; the media is not loaded at all.
    private(set) var showsPlayer: Bool
    /// The waveform and its timing tools; off: nothing is decoded for it.
    private(set) var isTimingModeOn: Bool
    private(set) var hasSelection = false
    /// Shown over the grid while it is empty.
    private(set) var subtitlesPlaceholder: String?
    private(set) var shownJobID: UUID?
    /// Edit or Translate for a subtitle file; nil for a transcription.
    private(set) var subtitleMode: JobQueueViewModel.SubtitleMode?

    /// Edits to the shown job, for the queue to keep.
    @ObservationIgnored var onEdit: (UUID, [TimedText]) -> Void = { _, _ in }
    /// Switches the shown subtitle file to the other mode, with the editor's lines.
    @ObservationIgnored var onSwitchMode: (UUID, JobQueueViewModel.SubtitleMode, [TimedText]) -> Void = { _, _, _ in }

    init(userDefaults: UserDefaults = .standard, waveformLoader: WaveformLoader = WaveformLoader()) {
        self.userDefaults = userDefaults
        waveform = WaveformViewModel(loader: waveformLoader)
        showsPlayer = userDefaults.object(forKey: Self.showsPlayerKey) == nil || userDefaults.bool(forKey: Self.showsPlayerKey)
        isTimingModeOn = userDefaults.bool(forKey: Self.timingModeKey)
        editor.setPrefersSourceColumn(userDefaults.object(forKey: Self.sourceColumnKey) == nil || userDefaults.bool(forKey: Self.sourceColumnKey))
        editor.onChange = { [weak self] lines in
            if let self, let jobID = shownJobID {
                onEdit(jobID, lines)
            }
        }
    }

    /// Audio files get only the playback controls, no picture area.
    var isAudioOnly: Bool {
        mediaURL.map { Self.audioExtensions.contains($0.pathExtension.lowercased()) } ?? false
    }

    /// Hidden by the user, or nothing to play (a subtitle file on its own).
    var showsPlayerArea: Bool {
        showsPlayer && mediaURL != nil
    }

    /// What the player should load: nothing while it is hidden.
    var playerURL: URL? {
        showsPlayer ? mediaURL : nil
    }

    /// The line being spoken, shown over the video.
    var currentSubtitle: String? {
        editor.playingIndex.flatMap { editor.lines.indices.contains($0) ? editor.lines[$0].text : nil }
    }

    /// Timing mode needs something to play.
    var canUseTimingMode: Bool {
        mediaURL != nil
    }

    /// The waveform shows with the player, in timing mode.
    var showsWaveform: Bool {
        isTimingModeOn && showsPlayerArea
    }

    func togglePlayer() {
        showsPlayer.toggle()
        userDefaults.set(showsPlayer, forKey: Self.showsPlayerKey)
        updateWaveform()
    }

    func toggleTimingMode() {
        isTimingModeOn.toggle()
        userDefaults.set(isTimingModeOn, forKey: Self.timingModeKey)
        updateWaveform()
    }

    func toggleSourceColumn() {
        let prefers = !editor.prefersSourceColumn
        editor.setPrefersSourceColumn(prefers)
        userDefaults.set(prefers, forKey: Self.sourceColumnKey)
    }

    private func updateWaveform() {
        waveform.show(showsWaveform ? mediaURL : nil)
    }

    /// Shows `job`, or nothing. A finished job with written files can be edited.
    func show(_ job: Job?) {
        hasSelection = job != nil
        guard let job else {
            shownJobID = nil
            subtitleMode = nil
            mediaURL = nil
            editor.load([], isEditable: false)
            updateWaveform()
            subtitlesPlaceholder = nil
            return
        }
        subtitleMode = JobQueueViewModel.subtitleMode(of: job)
        let isEditable = job.status == .completed && !job.outputURLs.isEmpty
        if shownJobID != job.id {
            shownJobID = job.id
            mediaURL = job.mediaURL
            editor.load(job.segments, originalLines: job.linesBeforeLanguageModel, isEditable: isEditable)
            updateWaveform()
        } else {
            editor.follow(job.segments, originalLines: job.linesBeforeLanguageModel, isEditable: isEditable)
        }
        let isEmpty = editor.lines.isEmpty
        subtitlesPlaceholder = switch job.status {
        case .completed: isEmpty ? String(localized: "No speech was found in this file.") : nil
        case .failed, .cancelled: isEmpty ? String(localized: "No subtitles.") : nil
        default: isEmpty ? String(localized: "Subtitles appear here as they are made.") : nil
        }
    }

    func switchMode(to mode: JobQueueViewModel.SubtitleMode) {
        if let jobID = shownJobID, mode != subtitleMode {
            onSwitchMode(jobID, mode, editor.lines)
        }
    }

    func playbackTimeChanged(to seconds: Double, isPlaying: Bool = false) {
        guard seconds.isFinite else { return }
        editor.playbackTimeChanged(to: AudioTime(seconds: max(seconds, 0)), isPlaying: isPlaying)
    }
}
