import Foundation
import Testing
import TranscriberCore
@testable import MediaDecoding

/// Compares against faster-whisper's decode_audio (PyAV 15.1 / FFmpeg 7.1),
/// fixtures from Tools/parity/make_decode_fixture.py.
struct MediaDecoderTests {
    /// One step of the s16 output, the format both decoders resample to.
    private static let leastSignificantBit: Float = 1 / 32_768
    /// AAC end padding: FFmpeg 9 trims it, the FFmpeg 7.1 inside PyAV does not,
    /// so the last samples (at most one 1024-sample AAC frame at 44.1 kHz) differ.
    private static let aacTailSampleCount = 1_024 * 16_000 / 44_100

    @Test func pcmMatchesFasterWhisperExactly() throws {
        let audio = try MediaDecoder().decodeAudio(at: try Self.fixtureURL("stereo-44k.wav"))
        let expected = try Self.loadFloats("stereo-44k.wav.f32")
        #expect(audio.samples == expected)
        #expect(audio.timestampJumps.isEmpty)
    }

    @Test func aacMatchesFasterWhisperExceptEndPadding() throws {
        let samples = try MediaDecoder().decodeAudio(at: try Self.fixtureURL("stereo-44k.m4a")).samples
        let expected = try Self.loadFloats("stereo-44k.m4a.f32")

        #expect(abs(samples.count - expected.count) <= Self.aacTailSampleCount)
        let comparedCount = min(samples.count, expected.count) - Self.aacTailSampleCount
        #expect(samples.prefix(comparedCount) == expected.prefix(comparedCount))
    }

    /// timestamp-gap.m4a: 2 s of a 440 Hz tone with the second half moved
    /// 2 s later, so one AAC packet claims 2.064 s but holds 64 ms (the hole
    /// WhisperJAV found in real films):
    /// `ffmpeg -f lavfi -i sine=frequency=440:sample_rate=16000:duration=2
    ///  -af "asetpts='if(gte(PTS,16000),PTS+32000,PTS)'" -c:a aac timestamp-gap.m4a`
    @Test func fillsTimestampHoleWithSilence() throws {
        let audio = try MediaDecoder().decodeAudio(at: try Self.fixtureURL("timestamp-gap.m4a"))

        let jump = try #require(audio.timestampJumps.only)
        #expect(abs(jump.offset.seconds - 2) < 0.01)
        #expect(abs(jump.position.seconds - 1.024) < 0.07)
        // The tone resumes 2 s later than when the frames are joined.
        #expect(abs(audio.duration.seconds - 4) < 0.07)
        let hole = audio.samples[AudioTime(seconds: 1.2).samples..<AudioTime(seconds: 2.8).samples]
        #expect(hole.allSatisfy { $0 == 0 })
        let afterHole = audio.samples[AudioTime(seconds: 3.2).samples..<AudioTime(seconds: 3.5).samples]
        #expect(afterHole.contains { abs($0) > 0.1 })
    }

    @Test func deliversTheSameSamplesInPieces() throws {
        let url = try Self.fixtureURL("timestamp-gap.m4a")
        let whole = try MediaDecoder().decodeAudio(at: url)
        var pieces: [[Float]] = []
        let jumps = try MediaDecoder().decodeAudio(at: url, chunkSize: 4_000) { pieces.append($0) }
        #expect(pieces.count > 1)
        #expect(pieces.flatMap { $0 } == whole.samples)
        #expect(jumps == whole.timestampJumps)  // positions count the samples already handed over
    }

    @Test func joiningFramesReportsTheHoleButKeepsTheOriginalBehavior() throws {
        let audio = try MediaDecoder(timestampHandling: .joinFrames).decodeAudio(at: try Self.fixtureURL("timestamp-gap.m4a"))

        #expect(audio.timestampJumps.count == 1)
        #expect(abs(audio.duration.seconds - 2) < 0.07)
    }

    @Test func smallTimestampJitterIsNotAJump() {
        var tracker = AudioTimestampTracker()
        #expect(tracker.jump(atFrameStartingAt: 0, durationSeconds: 0.064) == nil)
        #expect(tracker.jump(atFrameStartingAt: 0.064 + 0.05, durationSeconds: 0.064) == nil)
        #expect(tracker.jump(atFrameStartingAt: 0.178 - 0.2, durationSeconds: 0.064) == -0.2)
    }

    @Test func reportsMissingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/audio.mp3")
        #expect(throws: MediaDecodingError.self) {
            try MediaDecoder().decodeAudio(at: url)
        }
    }

    private static func fixtureURL(_ fileName: String) throws -> URL {
        let name = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        return try #require(Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"))
    }

    private static func loadFloats(_ fileName: String) throws -> [Float] {
        try Data(contentsOf: try fixtureURL(fileName)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

private extension Array {
    /// The single element, or `nil` if there are none or several.
    var only: Element? {
        count == 1 ? first : nil
    }
}
