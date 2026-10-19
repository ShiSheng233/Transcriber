import AudioOverview
import Foundation
import Testing
import TranscriberCore

/// The detail pane's remembered choices, kept in a defaults suite of the
/// test's own (never the app's), and what showing a job does.
final class JobDetailViewModelTests {
    private let suiteName = "TranscriberTests.JobDetail.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let loader = WaveformLoader()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeViewModel() -> JobDetailViewModel {
        JobDetailViewModel(userDefaults: defaults, waveformLoader: loader)
    }

    private static let mediaURL = URL(filePath: "/nonexistent/TranscriberTests/film.mp4")

    private static func editingJob(lines: [TimedText] = TestLines.three, mediaURL: URL? = mediaURL) -> Job {
        Job(editing: URL(filePath: "/nonexistent/TranscriberTests/film.srt"), mediaURL: mediaURL, lines: lines)
    }

    @Test func startsWithThePlayerAndTheOriginalTextOnly() {
        let detail = makeViewModel()
        #expect(detail.showsPlayer)
        #expect(!detail.isTimingModeOn)
        #expect(!detail.showsEditingTools)
        #expect(detail.editor.prefersSourceColumn)
        #expect(detail.editor.checksSpellingWhileTyping)
        #expect(detail.playerVolume == 1)
        #expect(!detail.isPlayerMuted)
    }

    @Test func togglesAreRememberedForTheNextLaunch() {
        let detail = makeViewModel()
        detail.togglePlayer()
        detail.toggleTimingMode()
        detail.toggleEditingTools()
        detail.toggleSourceColumn()
        detail.toggleSpellingWhileTyping()
        let relaunched = makeViewModel()
        #expect(!relaunched.showsPlayer)
        #expect(relaunched.isTimingModeOn)
        #expect(relaunched.showsEditingTools)
        #expect(!relaunched.editor.prefersSourceColumn)
        #expect(!relaunched.editor.checksSpellingWhileTyping)
        relaunched.toggleTimingMode()
        #expect(!makeViewModel().isTimingModeOn)
    }

    @Test func theSpectrogramChoiceIsRemembered() {
        let detail = makeViewModel()
        #expect(!detail.waveform.showsSpectrogram)
        detail.toggleSpectrogram()
        #expect(detail.waveform.showsSpectrogram)
        let relaunched = makeViewModel()
        #expect(relaunched.waveform.showsSpectrogram)
        relaunched.toggleSpectrogram()
        #expect(!makeViewModel().waveform.showsSpectrogram)
    }

    @Test func playerVolumeAndMuteAreRemembered() {
        makeViewModel().setPlayerVolume(0.25, isMuted: true)
        let relaunched = makeViewModel()
        #expect(relaunched.playerVolume == 0.25)
        #expect(relaunched.isPlayerMuted)
        // A volume of zero is kept, not taken for "never set".
        relaunched.setPlayerVolume(0, isMuted: false)
        #expect(makeViewModel().playerVolume == 0)
    }

    @Test func timingModeShowsTheWaveformInsteadOfTheVideo() {
        let detail = makeViewModel()
        detail.show(Self.editingJob())
        #expect(detail.showsVideo)
        #expect(!detail.showsWaveform)
        #expect(!detail.waveform.isLoading)
        detail.toggleTimingMode()
        #expect(!detail.showsVideo)
        #expect(detail.showsWaveform)
        #expect(detail.waveform.isLoading)
        // Hiding the player keeps the waveform's sound.
        detail.togglePlayer()
        #expect(detail.playerURL == Self.mediaURL)
        detail.toggleTimingMode()
        #expect(detail.playerURL == nil)
        #expect(!detail.waveform.isLoading)
    }

    @Test func aSubtitleFileWithoutMediaHasNothingToPlay() {
        let detail = makeViewModel()
        detail.toggleTimingMode()
        detail.show(Self.editingJob(mediaURL: nil))
        #expect(!detail.canUseTimingMode)
        #expect(!detail.showsPlayerArea)
        #expect(!detail.waveform.isLoading)
    }

    @Test func editsToTheShownJobAreReportedWithItsID() {
        let detail = makeViewModel()
        let job = Self.editingJob()
        var reported: (UUID, [TimedText])?
        detail.onEdit = { reported = ($0, $1) }
        detail.show(job)
        #expect(detail.editor.isEditable)
        detail.editor.select([0])
        detail.editor.setText("edited")
        #expect(reported?.0 == job.id)
        #expect(reported?.1.first?.text == "edited")
    }

    @Test func theSubtitleUnderThePlayheadIsShownOverTheVideo() {
        let detail = makeViewModel()
        detail.show(Self.editingJob())
        detail.playbackTimeChanged(to: 2.5)
        #expect(detail.currentSubtitle == "two")
        // A player without a time yet changes nothing.
        detail.playbackTimeChanged(to: .nan)
        #expect(detail.currentSubtitle == "two")
        detail.playbackTimeChanged(to: 1.5)
        #expect(detail.currentSubtitle == nil)
    }

    @Test func theShownJobsLanguageIsTheSpellCheckers() {
        let detail = makeViewModel()
        detail.show(Self.editingJob(), subtitleLanguage: "en")
        #expect(detail.editor.spellingLanguage == "en")
        detail.show(nil)
        #expect(detail.editor.spellingLanguage == nil)
    }

    @Test func showingNothingClearsTheEditor() {
        let detail = makeViewModel()
        detail.show(Self.editingJob(lines: []))
        #expect(detail.subtitlesPlaceholder == "No speech was found in this file.")
        detail.show(nil)
        #expect(!detail.hasSelection)
        #expect(detail.editor.lines.isEmpty)
        #expect(!detail.editor.isEditable)
        #expect(detail.subtitlesPlaceholder == nil)
    }
}
