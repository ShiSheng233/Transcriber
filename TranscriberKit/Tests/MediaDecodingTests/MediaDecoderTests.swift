import Foundation
import Testing
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
        let samples = try MediaDecoder().decodeAudio(at: try Self.fixtureURL("stereo-44k.wav"))
        let expected = try Self.loadFloats("stereo-44k.wav.f32")
        #expect(samples == expected)
    }

    @Test func aacMatchesFasterWhisperExceptEndPadding() throws {
        let samples = try MediaDecoder().decodeAudio(at: try Self.fixtureURL("stereo-44k.m4a"))
        let expected = try Self.loadFloats("stereo-44k.m4a.f32")

        #expect(abs(samples.count - expected.count) <= Self.aacTailSampleCount)
        let comparedCount = min(samples.count, expected.count) - Self.aacTailSampleCount
        #expect(samples.prefix(comparedCount) == expected.prefix(comparedCount))
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
