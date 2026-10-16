import Foundation
import TranscriberCore

extension Waveform {
    /// Louder than the quiet floor by this much counts as sound.
    static let speechAboveFloorDecibels: Float = 12
    /// The quiet floor: this fraction of bins are at or below it.
    static let floorPercentile = 0.2
    /// Never treat anything quieter than this as sound (−50 dBFS).
    static let minimumLevel: Float = 0.003
    /// Shorter dips do not split a stretch of sound.
    static let bridgedGap = AudioTime(milliseconds: 150)
    /// Shorter bursts (clicks) are not sound.
    static let minimumSpanDuration = AudioTime(milliseconds: 100)

    /// Where the audio is clearly louder than its own quiet floor: the
    /// starts and ends a timing tool can snap to. It is a loudness measure,
    /// not a speech model, so breaths and music count too.
    public func soundSpans() -> [SpeechSpan] {
        guard !levels.isEmpty else {
            return []
        }
        let sorted = levels.sorted()
        let floor = sorted[min(Int(Double(sorted.count) * Self.floorPercentile), sorted.count - 1)]
        let threshold = max(floor * pow(10, Self.speechAboveFloorDecibels / 20), Self.minimumLevel)

        var spans: [SpeechSpan] = []
        var spanStart: Int?
        for (bin, level) in levels.enumerated() {
            if level > threshold, spanStart == nil {
                spanStart = bin
            } else if level <= threshold, let start = spanStart {
                spans.append(span(fromBin: start, toBin: bin))
                spanStart = nil
            }
        }
        if let start = spanStart {
            spans.append(span(fromBin: start, toBin: levels.count))
        }

        var bridged: [SpeechSpan] = []
        for span in spans {
            if let last = bridged.last, span.start - last.end < Self.bridgedGap {
                bridged[bridged.count - 1].end = span.end
            } else {
                bridged.append(span)
            }
        }
        return bridged.filter { $0.duration >= Self.minimumSpanDuration }
    }

    private func span(fromBin start: Int, toBin end: Int) -> SpeechSpan {
        SpeechSpan(start: AudioTime(samples: start * Self.binDuration.samples), end: AudioTime(samples: min(end * Self.binDuration.samples, duration.samples)))
    }
}
