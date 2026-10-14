extension LogMelFeatures {
    /// faster-whisper's `pad_or_trim(features[:, start : start + frameCount])`:
    /// `frameCount` frames from `start`, then zeros up to `windowFrameCount`.
    /// Zeros are in normalized log-mel space, as faster-whisper pads them.
    public func paddedWindow(startingAt start: Int, frameCount: Int, windowFrameCount: Int = LogMelSpectrogram.windowFrameCount) -> LogMelFeatures {
        let copiedFrameCount = min(frameCount, windowFrameCount, self.frameCount - start)
        var window = [Float](repeating: 0, count: melBandCount * windowFrameCount)
        for band in 0..<melBandCount where copiedFrameCount > 0 {
            let source = band * self.frameCount + start
            let destination = band * windowFrameCount
            window[destination..<(destination + copiedFrameCount)] = values[source..<(source + copiedFrameCount)]
        }
        return LogMelFeatures(melBandCount: melBandCount, frameCount: windowFrameCount, values: window)
    }
}
