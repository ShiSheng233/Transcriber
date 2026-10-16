import Foundation
import Testing
import TranscriberCore
@testable import SubtitleExport

/// Expected files come from the original SubWriter
/// (Tools/parity/make_subtitle_fixture.py).
struct SubtitleRendererTests {
    private struct Segment: Decodable {
        let start: Int
        let end: Int
        let text: String
    }

    @Test(arguments: [SubtitleFormat.srt, .lrc, .txt])
    func matchesOriginalWriter(_ format: SubtitleFormat) throws {
        let rendered = SubtitleRenderer.render(try Self.segments(), as: format)
        #expect(rendered == (try Self.expected(format)))
    }

    @Test func vttDiffersFromOriginalOnlyInTheStandardHeader() throws {
        let rendered = SubtitleRenderer.render(try Self.segments(), as: .vtt)
        let original = try Self.expected(.vtt)
        #expect(original.hasPrefix("WebVTT\n"))
        #expect(rendered == "WEBVTT" + original.dropFirst("WebVTT".count))
    }

    @Test func assEscapesOverrideBracesAndNewlines() {
        let segment = TimedText(start: AudioTime(milliseconds: 3_723_456), end: AudioTime(milliseconds: 3_725_000), text: "{\\b1}一\n二")
        let rendered = SubtitleRenderer.render([segment], as: .ass)
        #expect(rendered.hasSuffix("Dialogue: 0,1:02:03.45,1:02:05.00,Default,,0,0,0,,｛\\b1｝一\\N二\n"))
    }

    private static let bilingual = [
        TimedText(start: .zero, end: AudioTime(seconds: 1), text: "你好"),
        TimedText(start: AudioTime(seconds: 2), end: AudioTime(seconds: 3), text: "谢谢"),
        TimedText(start: AudioTime(seconds: 3), end: AudioTime(seconds: 4), text: "同じ"),
    ]
    private static let originals: [String?] = ["こんにちは", nil, "同じ"]

    @Test func bilingualCuesPutTheOriginalOnTheNextLine() {
        let rendered = SubtitleRenderer.render(Self.bilingual, as: .srt, originals: Self.originals)
        #expect(rendered.contains("00:00:00,000 --> 00:00:01,000\n你好\nこんにちは\n\n"))
        #expect(rendered.contains("00:00:02,000 --> 00:00:03,000\n谢谢\n\n"))  // no original
        #expect(rendered.contains("00:00:03,000 --> 00:00:04,000\n同じ\n\n"))  // same as the line: not repeated
    }

    @Test func bilingualLyricsRepeatTheStartTime() {
        let rendered = SubtitleRenderer.render(Self.bilingual, as: .lrc, originals: Self.originals)
        #expect(rendered.hasPrefix("[00:00.00]你好\n[00:00.00]こんにちは\n[00:01.00]\n[00:02.00]谢谢\n"))
    }

    @Test func bilingualASSUsesTheOriginalStyle() {
        let rendered = SubtitleRenderer.render(Self.bilingual, as: .ass, originals: Self.originals)
        #expect(rendered.contains("Style: Original,"))
        #expect(rendered.contains(",,你好\\N{\\rOriginal}こんにちは\n"))
    }

    private static func segments() throws -> [TimedText] {
        let url = try #require(Bundle.module.url(forResource: "segments", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([Segment].self, from: Data(contentsOf: url)).map {
            TimedText(start: AudioTime(milliseconds: $0.start), end: AudioTime(milliseconds: $0.end), text: $0.text)
        }
    }

    private static func expected(_ format: SubtitleFormat) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "expected", withExtension: format.fileExtension, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
