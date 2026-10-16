import AudioOverview
import Foundation
import Observation
import TranscriberCore

/// The waveform under the player: the shown file's audio summary, loaded in
/// the background while timing mode is on, and the zoom and scroll position.
@Observable
final class WaveformViewModel {
    /// Default zoom and its limits, in points per second of audio.
    static let defaultPointsPerSecond = 100.0
    static let pointsPerSecondRange = 10.0...2_000.0
    /// One zoom step (Zoom In / Zoom Out).
    static let zoomStep = 1.5

    private(set) var waveform: Waveform?
    /// Where the audio is louder than its quiet floor.
    private(set) var soundSpans: [SpeechSpan] = []
    /// Where the VAD heard speech when the file was transcribed.
    private(set) var speechSpans: [SpeechSpan] = []
    private(set) var isLoading = false
    /// Why the waveform could not be loaded; `nil` unless loading failed.
    private(set) var loadFailureMessage: String?
    private(set) var pointsPerSecond = defaultPointsPerSecond
    /// The time at the left edge.
    private(set) var visibleStart = AudioTime.zero

    @ObservationIgnored private let loader: WaveformLoader
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(loader: WaveformLoader) {
        self.loader = loader
    }

    var duration: AudioTime {
        waveform?.duration ?? .zero
    }

    /// What times snap to: the speech the VAD found, or else the loud parts
    /// of the waveform (a subtitle file was never transcribed); `nil` when
    /// neither is known yet.
    var snapSpans: [SpeechSpan]? {
        if !speechSpans.isEmpty {
            return speechSpans
        }
        return waveform == nil ? nil : soundSpans
    }

    func setSpeechSpans(_ spans: [SpeechSpan]) {
        if spans != speechSpans {
            speechSpans = spans
        }
    }

    /// Loads `url`'s waveform unless it is already shown; `nil` unloads.
    func show(_ url: URL?) {
        guard url != loadedURL else { return }
        loadTask?.cancel()
        loadedURL = url
        waveform = nil
        soundSpans = []
        loadFailureMessage = nil
        visibleStart = .zero
        guard let url else {
            isLoading = false
            return
        }
        isLoading = true
        loadTask = Task { [loader] in
            let result = await Task.detached(priority: .utility) { () -> (Waveform, [SpeechSpan])? in
                guard let waveform = try? await loader.waveform(for: url) else { return nil }
                return (waveform, waveform.soundSpans())
            }.value
            guard !Task.isCancelled, loadedURL == url else { return }
            isLoading = false
            if let (waveform, spans) = result {
                self.waveform = waveform
                soundSpans = spans
            } else {
                loadFailureMessage = Self.failureMessage(for: url)
            }
        }
    }

    /// Loads the shown file again after it failed (its drive reconnected,
    /// the file put back). The loader keeps only waveforms it read, so
    /// this decodes again.
    func retry() {
        guard loadFailureMessage != nil, let url = loadedURL else { return }
        loadedURL = nil
        show(url)
    }

    private static func failureMessage(for url: URL) -> String {
        FileManager.default.fileExists(atPath: url.path)
            ? String(localized: "The audio could not be read.")
            : String(localized: "The file could not be found.")
    }

    // MARK: Zoom and scroll

    func time(atX x: Double) -> AudioTime {
        visibleStart + AudioTime(seconds: x / pointsPerSecond)
    }

    func x(of time: AudioTime) -> Double {
        (time - visibleStart).seconds * pointsPerSecond
    }

    /// Zooms by `factor` keeping the time under `anchorX` in place.
    func zoom(by factor: Double, anchorX: Double, width: Double) {
        let anchor = time(atX: anchorX)
        let range = Self.pointsPerSecondRange
        pointsPerSecond = min(max(pointsPerSecond * factor, range.lowerBound), range.upperBound)
        scroll(to: anchor - AudioTime(seconds: anchorX / pointsPerSecond), width: width)
    }

    func scroll(byPoints points: Double, width: Double) {
        scroll(to: visibleStart + AudioTime(seconds: points / pointsPerSecond), width: width)
    }

    /// Shows `start` at the left edge, never past either end of the audio.
    func scroll(to start: AudioTime, width: Double) {
        let visible = AudioTime(seconds: width / pointsPerSecond)
        let latest = duration > visible ? duration - visible : .zero
        visibleStart = min(max(start, .zero), latest)
    }

    /// While playing, a playhead past this fraction of the width turns the page…
    private static let pageTurnFraction = 0.9
    /// …so that it lands at this fraction.
    private static let pageStartFraction = 0.1

    /// Keeps the playhead on screen while playing, a page at a time (a
    /// jump, no animation).
    func follow(playhead time: AudioTime, width: Double) {
        let x = x(of: time)
        if x < 0 || x > width * Self.pageTurnFraction {
            scroll(to: time - AudioTime(seconds: width * Self.pageStartFraction / pointsPerSecond), width: width)
        }
    }

    /// Centers a line that is off screen.
    func reveal(_ line: TimedText, width: Double) {
        let visibleEnd = time(atX: width)
        guard line.end < visibleStart || line.start > visibleEnd else { return }
        let middle = line.start + AudioTime(samples: (line.end - line.start).samples / 2)
        scroll(to: middle - AudioTime(seconds: width / 2 / pointsPerSecond), width: width)
    }

    /// Zooms so the line fills 60% of the width, centered.
    func fit(_ line: TimedText, width: Double) {
        let margin = 0.2
        let seconds = max((line.end - line.start).seconds, 0.1)
        let range = Self.pointsPerSecondRange
        pointsPerSecond = min(max(width * (1 - 2 * margin) / seconds, range.lowerBound), range.upperBound)
        scroll(to: line.start - AudioTime(seconds: width * margin / pointsPerSecond), width: width)
    }
}
