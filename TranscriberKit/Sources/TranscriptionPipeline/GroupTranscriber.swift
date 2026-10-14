import AudioFeatures
import TranscriberCore
import WhisperDecoding

/// Decodes one speech group as one subtitle, timed by the group itself
/// (`SegmentationSettings.Mode.vadGroups`, for text-only models).
struct GroupTranscriber: Sendable {
    let segmentGenerator: SegmentGenerator
    let spectrogram: LogMelSpectrogram
    let leadingSilence: AudioTime
    let samplingSeed: UInt64

    func transcribe(_ group: AudioChunk, of samples: [Float]) throws -> [TimedText] {
        let groupSamples = samples[group.sampleRange(inAudioOfLength: samples.count)]
        guard !groupSamples.isEmpty else {
            return []
        }
        let signal = [Float](repeating: 0, count: leadingSilence.samples) + groupSamples
        var generator = SeededRandomNumberGenerator(seed: samplingSeed &+ UInt64(group.index))
        guard let text = try segmentGenerator.text(for: spectrogram.features(for: signal), generator: &generator) else {
            return []
        }
        return [TimedText(start: AudioTime(seconds: group.startSeconds), end: AudioTime(seconds: group.endSeconds), text: text)]
    }
}
