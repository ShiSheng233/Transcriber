import AudioOverview
import Foundation
import Testing
import TranscriberCore

/// The waveform's loading, what times snap to, and zoom and scroll, with
/// small WAV files decoded by the real loader (no disk cache).
struct WaveformViewModelTests {
    private static let loadTimeout = Duration.seconds(10)
    private static let pollInterval = Duration.milliseconds(10)

    private let audio = TestAudioFile()
    private let waveform = WaveformViewModel(loader: WaveformLoader())

    private func waitUntilLoaded() async throws {
        let deadline = ContinuousClock.now + Self.loadTimeout
        while waveform.isLoading {
            try #require(ContinuousClock.now < deadline, "the waveform never finished loading")
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    @Test func loadsAFileAndFindsItsLoudPart() async throws {
        try audio.writeTone(seconds: 1, between: 0.5)
        #expect(waveform.snapSpans == nil)
        waveform.show(audio.url)
        #expect(waveform.isLoading)
        try await waitUntilLoaded()
        #expect(waveform.loadFailureMessage == nil)
        #expect(waveform.duration == AudioTime(seconds: 2))
        let spans = try #require(waveform.snapSpans)
        #expect(spans.count == 1)
        #expect(abs(spans[0].start.seconds - 0.5) < 0.05)
        #expect(abs(spans[0].end.seconds - 1.5) < 0.05)
    }

    @Test func speechTheVADFoundWinsOverLoudness() async throws {
        try audio.writeTone(seconds: 1, between: 0.5)
        let speech = [SpeechSpan(start: AudioTime(seconds: 0.6), end: AudioTime(seconds: 1.2))]
        waveform.setSpeechSpans(speech)
        // Known before the waveform is.
        #expect(waveform.snapSpans == speech)
        waveform.show(audio.url)
        try await waitUntilLoaded()
        #expect(waveform.snapSpans == speech)
        waveform.setSpeechSpans([])
        #expect(waveform.snapSpans == waveform.soundSpans)
    }

    @Test func aMissingFileCanBeTriedAgainOnceItIsBack() async throws {
        waveform.show(audio.url)
        try await waitUntilLoaded()
        #expect(waveform.waveform == nil)
        #expect(waveform.loadFailureMessage == "The file could not be found.")
        try audio.writeTone(seconds: 1, between: 0.5)
        waveform.retry()
        #expect(waveform.isLoading)
        #expect(waveform.loadFailureMessage == nil)
        try await waitUntilLoaded()
        #expect(waveform.loadFailureMessage == nil)
        #expect(waveform.waveform != nil)
    }

    @Test func aFileThatIsNotAudioSaysSo() async throws {
        try audio.writeGarbage()
        waveform.show(audio.url)
        try await waitUntilLoaded()
        #expect(waveform.loadFailureMessage == "The audio could not be read.")
    }

    @Test func retryDoesNothingUnlessLoadingFailed() async throws {
        waveform.retry()
        #expect(!waveform.isLoading)
        try audio.writeTone(seconds: 1, between: 0.5)
        waveform.show(audio.url)
        try await waitUntilLoaded()
        waveform.retry()
        #expect(!waveform.isLoading)
        #expect(waveform.waveform != nil)
    }

    @Test func showingNothingUnloads() async throws {
        try audio.writeTone(seconds: 1, between: 0.5)
        waveform.show(audio.url)
        try await waitUntilLoaded()
        waveform.show(nil)
        #expect(waveform.waveform == nil)
        #expect(waveform.snapSpans == nil)
        #expect(!waveform.isLoading)
    }

    private func waitUntilSpectrogramLoaded() async throws {
        let deadline = ContinuousClock.now + Self.loadTimeout
        while waveform.isLoading || waveform.isLoadingSpectrogram {
            try #require(ContinuousClock.now < deadline, "the spectrogram never finished loading")
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    @Test func theSpectrogramIsMadeOnlyOnceItIsShown() async throws {
        try audio.writeTone(seconds: 1, between: 0.5)
        waveform.show(audio.url)
        try await waitUntilLoaded()
        #expect(!waveform.isLoadingSpectrogram)
        #expect(waveform.spectrogram == nil)
        waveform.setShowsSpectrogram(true)
        #expect(waveform.isLoadingSpectrogram)
        try await waitUntilSpectrogramLoaded()
        let spectrogram = try #require(waveform.spectrogram)
        #expect(spectrogram.duration == AudioTime(seconds: 2))
        // Kept for switching back.
        waveform.setShowsSpectrogram(false)
        #expect(waveform.spectrogram == spectrogram)
    }

    @Test func aFileOpenedWithTheSpectrogramShownGetsBoth() async throws {
        try audio.writeTone(seconds: 1, between: 0.5)
        waveform.setShowsSpectrogram(true)
        // Nothing to analyze before a file is shown.
        #expect(!waveform.isLoadingSpectrogram)
        waveform.show(audio.url)
        try await waitUntilSpectrogramLoaded()
        #expect(waveform.waveform != nil)
        #expect(waveform.spectrogram != nil)
        waveform.show(nil)
        #expect(waveform.spectrogram == nil)
        #expect(!waveform.isLoadingSpectrogram)
    }

    @Test func scrollingStopsAtBothEndsOfTheAudio() async throws {
        try audio.writeTone(seconds: 1, between: 0.5)
        waveform.show(audio.url)
        try await waitUntilLoaded()
        // 100 points per second: 100 points show one of the two seconds.
        let width = 100.0
        waveform.scroll(to: AudioTime(seconds: -1), width: width)
        #expect(waveform.visibleStart == .zero)
        waveform.scroll(to: AudioTime(seconds: 5), width: width)
        #expect(waveform.visibleStart == AudioTime(seconds: 1))
    }

    @Test func zoomKeepsTheAnchorInPlaceWithinItsLimits() async throws {
        try audio.writeTone(seconds: 1, between: 0.5)
        waveform.show(audio.url)
        try await waitUntilLoaded()
        let width = 100.0
        let anchor = waveform.time(atX: 50)
        waveform.zoom(by: 2, anchorX: 50, width: width)
        #expect(waveform.pointsPerSecond == 2 * WaveformViewModel.defaultPointsPerSecond)
        #expect(waveform.time(atX: 50) == anchor)
        waveform.zoom(by: 1_000, anchorX: 50, width: width)
        #expect(waveform.pointsPerSecond == WaveformViewModel.pointsPerSecondRange.upperBound)
    }

    @Test func followingThePlayheadTurnsAPage() async throws {
        try audio.writeTone(seconds: 1, between: 0.5)
        waveform.show(audio.url)
        try await waitUntilLoaded()
        let width = 100.0
        waveform.follow(playhead: AudioTime(seconds: 0.5), width: width)
        #expect(waveform.visibleStart == .zero)
        waveform.follow(playhead: AudioTime(seconds: 0.95), width: width)
        #expect(waveform.visibleStart == AudioTime(seconds: 0.85))
    }
}
