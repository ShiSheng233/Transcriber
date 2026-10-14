import Foundation
import Testing
import TranscriberCore
@testable import WhisperDecoding

/// Expected values from faster-whisper 1.2.1's own functions
/// (Tools/parity/make_segmentation_fixture.py).
struct SegmentationTests {
    private static let fixture = try! SegmentationFixture.load()
    private static let timestampBegin = 50364

    @Test func splitsLikeFasterWhisper() {
        let segmenter = TimestampSegmenter(timestampBegin: Self.timestampBegin)
        for testCase in Self.fixture.splitCases {
            let split = segmenter.split(
                tokens: testCase.tokens,
                timeOffset: Double(testCase.seek) * 0.01,
                segmentFrameCount: testCase.segmentSize,
                segmentDuration: Double(testCase.segmentSize) * 0.01,
                seek: testCase.seek
            )
            let expectedSegments = testCase.expectedSegments.map { TokenSegment(start: $0.start, end: $0.end, tokens: $0.tokens) }
            #expect(split.segments == expectedSegments, "\(testCase.tokens)")
            #expect(split.nextSeek == testCase.expectedSeek, "\(testCase.tokens)")
            #expect(split.endsWithSingleTimestamp == testCase.expectedSingleTimestampEnding)
        }
    }

    @Test func joinsSpeechLikeCollectChunks() {
        for testCase in Self.fixture.timelineCases {
            let samples = (0..<testCase.audioLength).map(Float.init)
            let joined = SpeechTimeline.joinedSpeech(from: samples, spans: testCase.speechSpans)
            let expected = testCase.expectedSourceRanges.flatMap { ($0[0]..<$0[1]).map(Float.init) }
            #expect(joined == expected)
        }
    }

    @Test func mapsTimesLikeSpeechTimestampsMap() {
        for testCase in Self.fixture.timelineCases where !testCase.spans.isEmpty {
            let timeline = SpeechTimeline(spans: testCase.speechSpans)
            for query in testCase.queries {
                #expect(timeline.originalTime(query.time, isEnd: false) == query.start, "\(query.time)")
                #expect(timeline.originalTime(query.time, isEnd: true) == query.end, "\(query.time)")
            }
        }
    }

    @Test func roundsLikePython() {
        for testCase in Self.fixture.roundingCases {
            #expect(testCase.value.pythonRounded(toPlaces: 2) == testCase.rounded, "\(testCase.value)")
            #expect(Int((testCase.value * 1_000).rounded(.toNearestOrEven)) == testCase.milliseconds, "\(testCase.value)")
        }
    }
}

struct SegmentationFixture: Decodable {
    struct SplitCase: Decodable {
        let tokens: [Int]
        let seek: Int
        let segmentSize: Int
        let expectedSegments: [Segment]
        let expectedSeek: Int
        let expectedSingleTimestampEnding: Bool
    }

    struct Segment: Decodable {
        let start: Double
        let end: Double
        let tokens: [Int]
    }

    struct TimelineCase: Decodable {
        struct Span: Decodable {
            let start: Int
            let end: Int
        }

        struct Query: Decodable {
            let time: Double
            let start: Double
            let end: Double
        }

        let spans: [Span]
        let audioLength: Int
        let expectedSourceRanges: [[Int]]
        let queries: [Query]

        var speechSpans: [SpeechSpan] {
            spans.map { SpeechSpan(start: AudioTime(samples: $0.start), end: AudioTime(samples: $0.end)) }
        }
    }

    struct RoundingCase: Decodable {
        let value: Double
        let rounded: Double
        let milliseconds: Int
    }

    let splitCases: [SplitCase]
    let timelineCases: [TimelineCase]
    let roundingCases: [RoundingCase]

    static func load() throws -> SegmentationFixture {
        guard let url = Bundle.module.url(forResource: "segmentation-cases", withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SegmentationFixture.self, from: Data(contentsOf: url))
    }
}
