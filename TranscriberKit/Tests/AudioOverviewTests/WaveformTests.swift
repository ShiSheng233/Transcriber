import Testing
import TranscriberCore
@testable import AudioOverview

struct WaveformTests {
    private static let rate = AudioTime.sampleRate

    @Test func summarizesPeaksAndLevelsPer10Milliseconds() {
        let samples = [Float](repeating: 0.5, count: 160) + [Float](repeating: -0.25, count: 80)
        let waveform = Waveform(samples: samples)
        #expect(waveform.peaks == [0.5, 0.25])
        #expect(waveform.levels == [0.5, 0.25])
        #expect(waveform.duration == AudioTime(samples: 240))
        #expect(waveform.peak(from: .zero, to: AudioTime(milliseconds: 20)) == 0.5)
        #expect(waveform.peak(from: AudioTime(milliseconds: 12), to: AudioTime(milliseconds: 13)) == 0.25)
    }

    @Test func findsLoudStretchesAboveTheQuietFloor() {
        let quiet = [Float](repeating: 0.001, count: Self.rate)  // 1 s
        let loud = [Float](repeating: 0.3, count: Self.rate / 2)  // 0.5 s
        let dip = [Float](repeating: 0.001, count: Self.rate / 10)  // 100 ms: bridged
        let click = [Float](repeating: 0.3, count: Self.rate / 20)  // 50 ms: ignored
        let waveform = Waveform(samples: quiet + loud + dip + loud + quiet + click + quiet)
        let spans = waveform.soundSpans()
        #expect(spans == [SpeechSpan(start: AudioTime(seconds: 1), end: AudioTime(seconds: 2.1))])
    }

    @Test func silenceHasNoSound() {
        #expect(Waveform(samples: [Float](repeating: 0, count: Self.rate)).soundSpans().isEmpty)
        #expect(Waveform(samples: []).soundSpans().isEmpty)
    }
}

extension WaveformTests {
    @Test func buildsTheSameWaveformFromPieces() {
        let samples = (0..<1_000).map { Float(($0 * 37) % 100) / 100 - 0.5 }
        var builder = Waveform.Builder()
        for piece in [samples[..<7], samples[7..<500], samples[500...]] {
            builder.append(Array(piece))
        }
        #expect(builder.finish() == Waveform(samples: samples))
    }
}
