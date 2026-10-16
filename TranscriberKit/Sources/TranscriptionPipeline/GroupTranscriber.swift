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

    /// - Parameter dropsRepetitionLoops: leave out text still repetitive
    ///   after every temperature (`SubtitleFilterSettings`).
    func transcribe(_ group: AudioChunk, of samples: [Float], dropsRepetitionLoops: Bool) throws -> [TimedText] {
        let groupSamples = samples[group.sampleRange(inAudioOfLength: samples.count)]
        guard !groupSamples.isEmpty else {
            return []
        }
        let signal = [Float](repeating: 0, count: leadingSilence.samples) + groupSamples
        var generator = SeededRandomNumberGenerator(seed: samplingSeed &+ UInt64(group.index))
        guard let decoded = try segmentGenerator.text(for: spectrogram.features(for: signal), generator: &generator) else {
            return []
        }
        if dropsRepetitionLoops, decoded.isRepetitionLoop(segmentGenerator.decoder.windowDecoder.settings) {
            return []
        }
        return [TimedText(
            start: AudioTime(seconds: group.startSeconds),
            end: AudioTime(seconds: group.endSeconds),
            text: decoded.text,
            confidence: decoded.confidence(settings: segmentGenerator.decoder.windowDecoder.settings)
        )]
    }
}
