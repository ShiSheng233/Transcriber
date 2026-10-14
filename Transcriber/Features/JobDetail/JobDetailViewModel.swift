import Foundation
import Observation
import TranscriberCore

/// The selected job's media and subtitles, and which line is playing.
@Observable
final class JobDetailViewModel {
    struct Line: Equatable {
        let timeText: String
        let text: String
        let startSeconds: Double
        let endSeconds: Double
    }

    private static let showsPlayerKey = "ShowsPlayer"
    private let userDefaults: UserDefaults

    private(set) var mediaURL: URL?
    /// Off: only the subtitle list; the media is not loaded at all.
    private(set) var showsPlayer: Bool
    private(set) var lines: [Line] = []
    private(set) var currentLineIndex: Int?
    /// Shown above the subtitle list while it is empty.
    private(set) var subtitlesPlaceholder: String?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        showsPlayer = userDefaults.object(forKey: Self.showsPlayerKey) as? Bool ?? true
    }

    var hasSelection: Bool {
        mediaURL != nil
    }

    private static let audioExtensions: Set<String> = ["mp3", "wav", "flac", "m4a", "aac", "ogg", "opus", "wma"]

    /// Audio files get only the playback controls, no picture area.
    var isAudioOnly: Bool {
        mediaURL.map { Self.audioExtensions.contains($0.pathExtension.lowercased()) } ?? false
    }

    /// What the player should load: nothing while it is hidden.
    var playerURL: URL? {
        showsPlayer ? mediaURL : nil
    }

    func togglePlayer() {
        showsPlayer.toggle()
        userDefaults.set(showsPlayer, forKey: Self.showsPlayerKey)
    }

    /// Shows `job`, or nothing. Keeps the media when only its status changed.
    func show(_ job: Job?) {
        guard let job else {
            mediaURL = nil
            lines = []
            currentLineIndex = nil
            subtitlesPlaceholder = nil
            return
        }
        if mediaURL != job.sourceURL {
            mediaURL = job.sourceURL
            currentLineIndex = nil
        }
        let newLines = job.segments.map(Self.line(for:))
        if newLines != lines {
            lines = newLines
        }
        subtitlesPlaceholder = switch job.status {
        case .completed: lines.isEmpty ? String(localized: "No speech was found in this file.") : nil
        case .failed, .cancelled: String(localized: "No subtitles.")
        default: lines.isEmpty ? String(localized: "Subtitles appear here as they are transcribed.") : nil
        }
    }

    /// The line being spoken, shown over the video.
    var currentSubtitle: String? {
        currentLineIndex.flatMap { lines.indices.contains($0) ? lines[$0].text : nil }
    }

    /// Highlights the line being spoken at `seconds`.
    func playbackTimeChanged(to seconds: Double) {
        let index = lines.firstIndex { seconds >= $0.startSeconds && seconds < $0.endSeconds }
        if index != currentLineIndex {
            currentLineIndex = index
        }
    }

    private static func line(for segment: TimedText) -> Line {
        Line(
            timeText: "\(clock(segment.start)) – \(clock(segment.end))",
            text: segment.text,
            startSeconds: segment.start.seconds,
            endSeconds: segment.end.seconds
        )
    }

    private static func clock(_ time: AudioTime) -> String {
        let total = time.milliseconds
        let hours = total / 3_600_000
        let minutes = total % 3_600_000 / 60_000
        let seconds = total % 60_000 / 1_000
        let tenths = total % 1_000 / 100
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes, seconds, tenths)
            : String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}
