import AudioFeatures
import TranscriberCore
import WhisperDecoding

/// Decodes one speech group as one subtitle, timed by the group itself
/// (`SegmentationSettings.Mode.vadGroups`, for text-only models).
struct GroupTranscriber: Sendable {
    typealias Recognize = @Sendable (_ signal: [Float], _ index: Int, _ dropsRepetitionLoops: Bool) async throws
        -> (text: String, confidence: RecognitionConfidence?)?

    let recognize: Recognize
    let leadingSilence: AudioTime

    init(recognize: @escaping Recognize, leadingSilence: AudioTime) {
        self.recognize = recognize
        self.leadingSilence = leadingSilence
    }

    init(segmentGenerator: SegmentGenerator, spectrogram: LogMelSpectrogram, leadingSilence: AudioTime, samplingSeed: UInt64) {
        self.init(recognize: { signal, index, dropsRepetitionLoops in
            var generator = SeededRandomNumberGenerator(seed: samplingSeed &+ UInt64(index))
            guard let decoded = try segmentGenerator.text(for: spectrogram.features(for: signal), generator: &generator) else {
                return nil
            }
            let decoding = segmentGenerator.decoder.windowDecoder.settings
            if dropsRepetitionLoops, decoded.isRepetitionLoop(decoding) { return nil }
            return (decoded.text, decoded.confidence(settings: decoding))
        }, leadingSilence: leadingSilence)
    }

    /// - Parameter dropsRepetitionLoops: leave out text still repetitive
    ///   after every temperature (`SubtitleFilterSettings`).
    func transcribe(_ group: AudioChunk, of samples: [Float], dropsRepetitionLoops: Bool) async throws -> [TimedText] {
        let groupSamples = samples[group.sampleRange(inAudioOfLength: samples.count)]
        guard !groupSamples.isEmpty else {
            return []
        }
        let signal = [Float](repeating: 0, count: leadingSilence.samples) + groupSamples
        guard let decoded = try await recognize(signal, group.index, dropsRepetitionLoops) else { return [] }
        return [TimedText(
            start: AudioTime(seconds: group.startSeconds),
            end: AudioTime(seconds: group.endSeconds),
            text: decoded.text,
            confidence: decoded.confidence
        )]
    }
}
