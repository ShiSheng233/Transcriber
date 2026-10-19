import Testing
import TranscriberCore
@testable import SubtitleExport

/// Times aligned to video frames are written in milliseconds (SRT, VTT) or
/// centiseconds (ASS), both truncated; read back, they must still be on the
/// frames they were aligned to.
struct FrameAlignedExportTests {
    @Test(arguments: [SubtitleFormat.srt, .vtt, .ass], [24_000.0 / 1_001, 25, 30_000.0 / 1_001, 60_000.0 / 1_001])
    func alignedTimesStayOnTheirFrames(_ format: SubtitleFormat, framesPerSecond: Double) throws {
        let frameCount = Int(framesPerSecond * 60 * 60)  // an hour
        let frames = try #require(VideoFrames(
            frameTimes: (0..<frameCount).map { AudioTime(seconds: Double($0) / framesPerSecond) },
            keyframeTimes: []
        ))
        // Lines at awkward times all through the hour.
        let lines = stride(from: 0.0137, to: 3_590, by: 7.31).map {
            TimedText(start: AudioTime(seconds: $0), end: AudioTime(seconds: $0 + 1.234_5), text: "line")
        }
        let aligned = SubtitleEditing.alignedToFrames([], in: lines, frames: frames).lines
        let rendered = SubtitleRenderer.render(aligned, as: format)
        let readBack = format == .ass ? Self.assTimes(rendered) : SubtitleParser.parse(rendered)
        try #require(readBack.count == aligned.count)
        for (written, read) in zip(aligned, readBack) {
            #expect(frames.firstFrame(shownFrom: read.start) == frames.firstFrame(shownFrom: written.start))
            #expect(frames.lastFrame(shownBefore: read.end) == frames.lastFrame(shownBefore: written.end))
        }
    }

    /// The times of ASS `Dialogue: layer,H:MM:SS.cc,H:MM:SS.cc,…` lines (the parser reads only SRT and VTT).
    private static func assTimes(_ text: String) -> [TimedText] {
        func time(_ field: Substring) -> AudioTime {
            let parts = field.split(separator: ":")
            let hours = Int(parts[0]) ?? 0
            let minutes = Int(parts[1]) ?? 0
            let seconds = parts[2].split(separator: ".")
            let milliseconds = ((hours * 60 + minutes) * 60 + (Int(seconds[0]) ?? 0)) * 1_000 + (Int(seconds[1]) ?? 0) * 10
            return AudioTime(milliseconds: milliseconds)
        }
        return text.split(separator: "\n").filter { $0.hasPrefix("Dialogue:") }.map { line in
            let fields = line.split(separator: ",", maxSplits: 3)
            return TimedText(start: time(fields[1]), end: time(fields[2]), text: "")
        }
    }
}
