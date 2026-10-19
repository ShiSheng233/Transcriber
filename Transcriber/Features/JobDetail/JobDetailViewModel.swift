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
    private static let spectrogramKey = "ShowsSpectrogram"
    private static let editingToolsKey = "ShowsEditingTools"
    private static let sourceColumnKey = "ShowsSourceColumn"
    private static let playerVolumeKey = "PlayerVolume"
    private static let playerMutedKey = "PlayerMuted"
    private static let audioExtensions: Set<String> = ["mp3", "wav", "flac", "m4a", "aac", "ogg", "opus", "wma"]
    private let userDefaults: UserDefaults

    let editor = SubtitleEditorViewModel()
    let waveform: WaveformViewModel
    private(set) var mediaURL: URL?
    /// Off: only the subtitles; the media is not loaded at all.
    private(set) var showsPlayer: Bool
    /// The waveform and its timing tools; off: nothing is decoded for it.
    private(set) var isTimingModeOn: Bool
    /// The editor's action bar; off by default, opened from the window toolbar.
    private(set) var showsEditingTools: Bool
    /// The player's volume (0…1) and mute, kept between files and launches.
    private(set) var playerVolume: Float
    private(set) var isPlayerMuted: Bool
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

    init(userDefaults: UserDefaults = .standard, waveformLoader: WaveformLoader) {
        self.userDefaults = userDefaults
        waveform = WaveformViewModel(loader: waveformLoader)
        showsPlayer = userDefaults.object(forKey: Self.showsPlayerKey) == nil || userDefaults.bool(forKey: Self.showsPlayerKey)
        isTimingModeOn = userDefaults.bool(forKey: Self.timingModeKey)
        showsEditingTools = userDefaults.bool(forKey: Self.editingToolsKey)
        playerVolume = userDefaults.object(forKey: Self.playerVolumeKey) == nil ? 1 : userDefaults.float(forKey: Self.playerVolumeKey)
        isPlayerMuted = userDefaults.bool(forKey: Self.playerMutedKey)
        editor.setPrefersSourceColumn(userDefaults.object(forKey: Self.sourceColumnKey) == nil || userDefaults.bool(forKey: Self.sourceColumnKey))
        waveform.setShowsSpectrogram(userDefaults.bool(forKey: Self.spectrogramKey))
        editor.onChange = { [weak self] lines in
            if let self, let jobID = shownJobID {
                onEdit(jobID, lines)
            }
        }
    }

    /// Remembers what the player's controls were set to.
    func setPlayerVolume(_ volume: Float, isMuted: Bool) {
        guard volume != playerVolume || isMuted != isPlayerMuted else { return }
        playerVolume = volume
        isPlayerMuted = isMuted
        userDefaults.set(volume, forKey: Self.playerVolumeKey)
        userDefaults.set(isMuted, forKey: Self.playerMutedKey)
    }

    /// Audio files get only the playback controls, no picture area.
    var isAudioOnly: Bool {
        mediaURL.map { Self.audioExtensions.contains($0.pathExtension.lowercased()) } ?? false
    }

    /// The video (or audio controls): shown unless hidden by the user, in
    /// timing mode, or with nothing to play (a subtitle file on its own).
    var showsVideo: Bool {
        showsPlayer && !isTimingModeOn && mediaURL != nil
    }

    /// The waveform takes the video's place in timing mode.
    var showsWaveform: Bool {
        isTimingModeOn && mediaURL != nil
    }

    /// Something to play is loaded: the video or the waveform is shown.
    var showsPlayerArea: Bool {
        showsVideo || showsWaveform
    }

    /// What the player should load: nothing while neither is shown.
    var playerURL: URL? {
        showsPlayerArea ? mediaURL : nil
    }

    /// The line being spoken, shown over the video.
    var currentSubtitle: String? {
        editor.playingIndex.flatMap { editor.lines.indices.contains($0) ? editor.lines[$0].text : nil }
    }

    /// Timing mode needs something to play.
    var canUseTimingMode: Bool {
        mediaURL != nil
    }

    func togglePlayer() {
        showsPlayer.toggle()
        userDefaults.set(showsPlayer, forKey: Self.showsPlayerKey)
        updateWaveform()
    }

    func toggleEditingTools() {
        showsEditingTools.toggle()
        userDefaults.set(showsEditingTools, forKey: Self.editingToolsKey)
    }

    func toggleTimingMode() {
        isTimingModeOn.toggle()
        userDefaults.set(isTimingModeOn, forKey: Self.timingModeKey)
        updateWaveform()
    }

    /// Timing mode's audio as a spectrogram or as peaks; off by default.
    func toggleSpectrogram() {
        let shows = !waveform.showsSpectrogram
        waveform.setShowsSpectrogram(shows)
        userDefaults.set(shows, forKey: Self.spectrogramKey)
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
            waveform.setSpeechSpans([])
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
        waveform.setSpeechSpans(job.speechSpans)
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
