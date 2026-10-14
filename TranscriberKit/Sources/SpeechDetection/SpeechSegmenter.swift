import TranscriberCore

/// Turns per-frame speech probabilities into speech spans.
///
/// A line-by-line port of `get_speech_timestamps_onnx` in ChickenRice's
/// `vad_manager.py`, checked against it by SpeechSegmenterTests:
/// hysteresis between `threshold` and the negative threshold, a minimum silence
/// before speech ends, minimum and maximum speech lengths, then padding that
/// never overlaps the neighboring span.
public enum SpeechSegmenter {
    /// The VAD model emits one probability per 20 ms.
    public static let frameDuration = AudioTime(milliseconds: 20)

    public static func speechSpans(in probabilities: [Float], settings: VADSettings) -> [SpeechSpan] {
        let frameCount = probabilities.count
        let minimumSpeechFrames = frames(in: settings.minimumSpeechDuration)
        let minimumSilenceFrames = frames(in: settings.minimumSilenceDuration)
        let paddingFrames = frames(in: settings.speechPadding)
        let maximumSpeechFrames = settings.maximumSpeechDuration.map(frames(in:)) ?? frameCount
        // Compared in float32, as NumPy 2 does for a float32 probability against
        // a Python float (NEP 50). The CUDA 12.x builds of the original resolve
        // NumPy 2; only the CUDA 11.8 build pins NumPy 1.26, which compares in
        // float64. The two differ only when a probability equals a threshold.
        let threshold = Float(settings.threshold)
        let negativeThreshold = Float(settings.resolvedNegativeThreshold)

        var spans: [FrameSpan] = []
        var speechStart: Int?
        var silenceStart: Int?

        for (frame, probability) in probabilities.enumerated() {
            guard let start = speechStart else {
                if probability >= threshold {
                    speechStart = frame
                }
                continue
            }

            if frame - start > maximumSpeechFrames {
                spans.append(FrameSpan(start: start, end: start + maximumSpeechFrames))
                speechStart = nil
                silenceStart = nil
                continue
            }

            if probability < negativeThreshold {
                let silence = silenceStart ?? frame
                silenceStart = silence
                if frame - silence >= minimumSilenceFrames {
                    if silence - start >= minimumSpeechFrames {
                        spans.append(FrameSpan(start: start, end: silence))
                    }
                    speechStart = nil
                    silenceStart = nil
                }
            } else if probability >= threshold {
                silenceStart = nil
            }
        }

        if let start = speechStart, frameCount - start >= minimumSpeechFrames {
            spans.append(FrameSpan(start: start, end: frameCount))
        }

        pad(&spans, by: paddingFrames, frameCount: frameCount)
        return spans.map { span in
            SpeechSpan(start: time(atFrame: span.start), end: time(atFrame: span.end))
        }
    }

    /// Pads in order, so each span's start is clamped to its predecessor's
    /// already-padded end, exactly as the original loop does.
    private static func pad(_ spans: inout [FrameSpan], by paddingFrames: Int, frameCount: Int) {
        for index in spans.indices {
            let previousEnd = index == spans.startIndex ? 0 : spans[index - 1].end
            let nextStart = index == spans.index(before: spans.endIndex) ? frameCount : spans[index + 1].start
            spans[index].start = max(previousEnd, spans[index].start - paddingFrames)
            spans[index].end = min(nextStart, spans[index].end + paddingFrames)
        }
    }

    /// `int(duration_ms / frame_duration_ms)`: whole frames, rounded down.
    private static func frames(in duration: AudioTime) -> Int {
        duration.milliseconds / frameDuration.milliseconds
    }

    private static func time(atFrame frame: Int) -> AudioTime {
        AudioTime(samples: frame * frameDuration.samples)
    }
}

private struct FrameSpan {
    var start: Int
    var end: Int
}
