import Testing
import TranscriberCore
@testable import SubtitleExport

struct SubtitleParserTests {
    @Test func readsSRTWithBOMCRLFAndMultilineCues() {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,500\r\nこんにちは\r\n\r\n2\r\n00:01:02,250 --> 00:01:04,000\r\n一行目\r\n二行目\r\n\r\n"
        let cues = SubtitleParser.parse(srt)
        #expect(cues.map(\.text) == ["こんにちは", "一行目\n二行目"])
        #expect(cues.map(\.start.milliseconds) == [1_000, 62_250])
        #expect(cues.map(\.end.milliseconds) == [2_500, 64_000])
    }

    @Test func readsVTTWithShortTimesSettingsAndNotes() {
        let vtt = "WEBVTT\n\nNOTE made by hand\n\ncue-1\n00:01.000 --> 00:02.000 align:start\nHello\n\n00:00:03.000 --> 00:00:04.000\nWorld\n"
        let cues = SubtitleParser.parse(vtt)
        #expect(cues.map(\.text) == ["Hello", "World"])
        #expect(cues.map(\.start.milliseconds) == [1_000, 3_000])
    }

    @Test func roundTripsOurOwnSRT() {
        let segments = [
            TimedText(start: AudioTime(milliseconds: 0), end: AudioTime(milliseconds: 3_720), text: "你好"),
            TimedText(start: AudioTime(milliseconds: 6_100), end: AudioTime(milliseconds: 12_000), text: "昨天"),
        ]
        #expect(SubtitleParser.parse(SubtitleRenderer.render(segments, as: .srt)) == segments)
    }
}
