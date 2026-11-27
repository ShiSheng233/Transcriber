import Foundation
import libavcodec
import libavformat
import libavutil
import TranscriberCore

/// Decodes the first audio stream of any supported media file to 16 kHz mono
/// `Float` samples, reproducing faster-whisper's `decode_audio` (PyAV/FFmpeg):
/// frames that fail with invalid data are skipped, and the resampler is
/// flushed at the end.
public struct MediaDecoder: Sendable {
    public enum TimestampHandling: Sendable {
        /// Fill holes with silence and drop overlaps, so the audio keeps the
        /// file's timeline. Identical to `joinFrames` for files without holes.
        case followTimestamps
        /// The original pipeline: frames end to end, whatever their timestamps.
        case joinFrames
    }

    private let timestampHandling: TimestampHandling

    public init(timestampHandling: TimestampHandling = .followTimestamps) {
        self.timestampHandling = timestampHandling
        _ = Self.loggingConfigured
    }

    /// FFmpeg warns about recoverable stream details (e.g. trimming AAC
    /// priming samples); only errors are worth showing.
    private static let loggingConfigured: Void = {
        av_log_set_level(AV_LOG_ERROR)
    }()

    public func decodeAudio(at url: URL) throws -> DecodedAudio {
        var output = try decode(at: url, deliveringEvery: nil) { _ in }
        return DecodedAudio(samples: output.takeSamples(), timestampJumps: output.timestampJumps)
    }

    /// Decodes speculatively only when the audio has a known duration under
    /// the budget. The resampler also enforces the budget on actual output.
    package func decodeAudio(at url: URL, upTo budget: AudioTime) throws -> DecodedAudio? {
        do {
            var output = try decode(at: url, deliveringEvery: nil, prefetchBudget: budget) { _ in }
            return DecodedAudio(samples: output.takeSamples(), timestampJumps: output.timestampJumps)
        } catch is AudioResampler.SampleLimitExceeded {
            return nil
        }
    }

    /// The same samples as `decodeAudio(at:)`, handed over in pieces of
    /// about `chunkSize` as they are decoded, so a long film never has to fit
    /// in memory at once. Returns the timestamp jumps.
    @discardableResult
    public func decodeAudio(
        at url: URL,
        chunkSize: Int = Self.defaultChunkSize,
        consume: ([Float]) throws -> Void
    ) throws -> [AudioTimestampJump] {
        try decode(at: url, deliveringEvery: max(chunkSize, 1), consume: consume).timestampJumps
    }

    /// The requested slice on the same timeline as a whole-file decode.
    package func decodeAudio(at url: URL, in range: Range<AudioTime>) throws -> [Float] {
        try Task.checkCancellation()
        let start = max(range.lowerBound, .zero)
        guard start < range.upperBound else { return [] }
        let samples = start.samples..<range.upperBound.samples
        let input = try MediaInput(url: url)
        if timestampHandling == .followTimestamps, start > Self.seekPreroll {
            if let slice = try? decodeAfterSeeking(input, range: samples), !slice.isEmpty {
                try Task.checkCancellation()
                return slice
            }
            try Task.checkCancellation()
            // A failed seek may have moved the demuxer. Reopen at the start.
            return try decodeRange(MediaInput(url: url), range: samples)
        }
        return try decodeRange(input, range: samples)
    }

    /// Start the codec and resampler before the requested audio, so neither
    /// their startup delay nor the demuxer's seek granularity clips the slice.
    private static let seekPreroll = AudioTime(seconds: 2)
    private static let minimumSeekPreroll = AudioTime(seconds: 0.25)
    /// Covers container rounding and the resampler's small delay, while a
    /// hole or overlap in the seek window triggers the sequential path.
    private static let seekClockTolerance = AudioTime(milliseconds: 20)
    private static let sampleTimeBase = AVRational(num: 1, den: Int32(AudioTime.sampleRate))

    private enum RangeSeekError: Error {
        case unreliableTimestamps
    }

    private func decodeAfterSeeking(_ input: MediaInput, range: Range<Int>) throws -> [Float] {
        // The full-file resampler starts at the first decoded frame's PTS.
        // Container start times and packet timestamps may include codec priming.
        var origin = AudioResampler.noTimestamp
        try readFrames(from: input) { frame in
            origin = frame.pointee.best_effort_timestamp
            return false
        }
        guard origin != AudioResampler.noTimestamp else { throw RangeSeekError.unreliableTimestamps }
        let prerollStart = Int64(range.lowerBound - Self.seekPreroll.samples)
        let distance = av_rescale_q(prerollStart, Self.sampleTimeBase, input.timeBase)
        let (target, overflow) = origin.addingReportingOverflow(distance)
        guard !overflow, distance >= 0,
              av_seek_frame(input.formatContext, input.audioStreamIndex, target, AVSEEK_FLAG_BACKWARD) >= 0 else {
            throw RangeSeekError.unreliableTimestamps
        }
        avcodec_flush_buffers(input.codecContext)
        return try decodeRange(input, range: range, seekOrigin: origin)
    }

    private func decodeRange(_ input: MediaInput, range: Range<Int>, seekOrigin: Int64? = nil) throws -> [Float] {
        let resampler = AudioResampler(followsTimestamps: timestampHandling == .followTimestamps)
        var output = Output(resampler: resampler, timeBase: input.timeBase)
        var firstFrame = true
        try readFrames(from: input) { frame in
            if let seekOrigin {
                let timestamp = frame.pointee.best_effort_timestamp
                let (relative, overflow) = timestamp.subtractingReportingOverflow(seekOrigin)
                guard timestamp != AudioResampler.noTimestamp, !overflow, relative >= 0 else {
                    throw RangeSeekError.unreliableTimestamps
                }
                let position = Int(av_rescale_q(relative, input.timeBase, Self.sampleTimeBase))
                if firstFrame {
                    guard position >= 0, position <= range.lowerBound - Self.minimumSeekPreroll.samples else {
                        throw RangeSeekError.unreliableTimestamps
                    }
                    output.deliveredSampleCount = position
                    firstFrame = false
                } else {
                    let expected = output.deliveredSampleCount + output.samples.count
                    let tolerance = Self.seekClockTolerance.samples
                    guard position >= expected - tolerance, position <= expected + tolerance else {
                        throw RangeSeekError.unreliableTimestamps
                    }
                }
            }
            try output.append(frame, recordsJumps: false)
            output.discardSamples(before: range.lowerBound)
            return output.samples.count < range.count
        }
        if output.samples.count < range.count {
            try resampler.flush(into: &output.samples)
            output.discardSamples(before: range.lowerBound)
        }
        if output.samples.count > range.count {
            output.samples.removeLast(output.samples.count - range.count)
        }
        try Task.checkCancellation()
        return output.samples
    }

    /// One minute of audio.
    public static let defaultChunkSize = 60 * AudioTime.sampleRate

    private func decode(
        at url: URL, deliveringEvery chunkSize: Int?, prefetchBudget: AudioTime? = nil, consume: ([Float]) throws -> Void
    ) throws -> Output {
        try Task.checkCancellation()
        let input = try MediaInput(url: url)
        if let prefetchBudget, !input.hasKnownDuration(upTo: prefetchBudget) {
            throw AudioResampler.SampleLimitExceeded.exceeded
        }
        let resampler = AudioResampler(followsTimestamps: timestampHandling == .followTimestamps, maximumSamples: prefetchBudget?.samples)
        var output = Output(resampler: resampler, timeBase: input.timeBase)
        try readFrames(from: input) { frame in
            try output.append(frame)
            if let chunkSize, output.samples.count >= chunkSize {
                try consume(output.takeSamples())
            }
            return true
        }
        try output.resampler.flush(into: &output.samples)
        if chunkSize != nil, !output.samples.isEmpty {
            try consume(output.takeSamples())
        }
        return output
    }

    /// Visits decoded audio frames until EOF (including delayed frames) or
    /// until the caller has enough samples.
    private func readFrames(
        from input: MediaInput, consume: (UnsafeMutablePointer<AVFrame>) throws -> Bool
    ) throws {
        try Task.checkCancellation()
        guard let packet = av_packet_alloc() else {
            throw MediaDecodingError.decodingFailed(FFmpegError(code: -ENOMEM))
        }
        var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetPointer) }
        guard let frame = av_frame_alloc() else {
            throw MediaDecodingError.decodingFailed(FFmpegError(code: -ENOMEM))
        }
        var framePointer: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&framePointer) }

        while av_read_frame(input.formatContext, packet) >= 0 {
            defer { av_packet_unref(packet) }
            try Task.checkCancellation()
            guard packet.pointee.stream_index == input.audioStreamIndex else {
                continue
            }
            if try !decode(packet, with: input.codecContext, frame: frame, consume: consume) {
                return
            }
        }

        // A nil packet drains the decoder's delayed frames.
        _ = try decode(nil, with: input.codecContext, frame: frame, consume: consume)
    }

    /// What decoding has produced so far.
    private struct Output {
        let resampler: AudioResampler
        let timeBase: AVRational
        var samples: [Float] = []
        /// Samples already handed over and removed from `samples`.
        var deliveredSampleCount = 0
        var timestampJumps: [AudioTimestampJump] = []
        var timestampTracker = AudioTimestampTracker()

        mutating func takeSamples() -> [Float] {
            deliveredSampleCount += samples.count
            defer { samples = [] }
            return samples
        }

        mutating func discardSamples(before position: Int) {
            let count = min(position - deliveredSampleCount, samples.count)
            guard count > 0 else { return }
            if count == samples.count {
                samples.removeAll(keepingCapacity: true)
            } else {
                samples.removeFirst(count)
            }
            deliveredSampleCount += count
        }

        mutating func append(_ frame: UnsafeMutablePointer<AVFrame>, recordsJumps: Bool = true) throws {
            let timestamp = frame.pointee.best_effort_timestamp
            if recordsJumps, timestamp != AudioResampler.noTimestamp, frame.pointee.sample_rate > 0 {
                let startSeconds = Double(timestamp) * av_q2d(timeBase)
                let durationSeconds = Double(frame.pointee.nb_samples) / Double(frame.pointee.sample_rate)
                if let jump = timestampTracker.jump(atFrameStartingAt: startSeconds, durationSeconds: durationSeconds) {
                    // Reject oversized holes before libswresample injects silence.
                    if let limit = resampler.maximumSamples,
                       jump > AudioTime(samples: limit - samples.count).seconds {
                        throw AudioResampler.SampleLimitExceeded.exceeded
                    }
                    timestampJumps.append(AudioTimestampJump(
                        position: AudioTime(samples: deliveredSampleCount + samples.count),
                        offset: AudioTime(seconds: jump)
                    ))
                }
            }
            try resampler.resample(frame, timeBase: timeBase, into: &samples)
        }
    }

    private func decode(
        _ packet: UnsafeMutablePointer<AVPacket>?,
        with codecContext: UnsafeMutablePointer<AVCodecContext>,
        frame: UnsafeMutablePointer<AVFrame>,
        consume: (UnsafeMutablePointer<AVFrame>) throws -> Bool
    ) throws -> Bool {
        let sendStatus = avcodec_send_packet(codecContext, packet)
        if sendStatus == FFmpegError.invalidData.code {
            return true
        }
        guard sendStatus >= 0 || sendStatus == FFmpegError.endOfFile.code else {
            throw MediaDecodingError.decodingFailed(FFmpegError(code: sendStatus))
        }

        while true {
            let receiveStatus = avcodec_receive_frame(codecContext, frame)
            if receiveStatus == FFmpegError.tryAgain.code || receiveStatus == FFmpegError.endOfFile.code {
                return true
            }
            if receiveStatus == FFmpegError.invalidData.code {
                continue
            }
            guard receiveStatus >= 0 else {
                throw MediaDecodingError.decodingFailed(FFmpegError(code: receiveStatus))
            }
            defer { av_frame_unref(frame) }
            if try !consume(frame) { return false }
        }
    }
}

/// An opened media file with a decoder for its first audio stream (PyAV's `audio=0`).
private final class MediaInput {
    let formatContext: UnsafeMutablePointer<AVFormatContext>
    let codecContext: UnsafeMutablePointer<AVCodecContext>
    let audioStreamIndex: Int32
    /// The unit of the stream's packet and frame timestamps.
    let timeBase: AVRational
    private let streamDuration: Int64

    init(url: URL) throws(MediaDecodingError) {
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        let openStatus = avformat_open_input(&formatContext, url.path, nil, nil)
        guard openStatus >= 0, let formatContext else {
            throw .openFailed(url, FFmpegError(code: openStatus))
        }
        var openedFormatContext: UnsafeMutablePointer<AVFormatContext>? = formatContext

        let streamInfoStatus = avformat_find_stream_info(formatContext, nil)
        guard streamInfoStatus >= 0 else {
            avformat_close_input(&openedFormatContext)
            throw .openFailed(url, FFmpegError(code: streamInfoStatus))
        }

        let streams = UnsafeBufferPointer(start: formatContext.pointee.streams, count: Int(formatContext.pointee.nb_streams))
        guard let audioStream = streams.lazy.compactMap({ $0 }).first(where: {
            $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
        }) else {
            avformat_close_input(&openedFormatContext)
            throw .noAudioStream(url)
        }
        // Let the demuxer skip non-target packets before reading their payloads when it can.
        for case let stream? in streams where stream != audioStream {
            stream.pointee.discard = AVDISCARD_ALL
        }

        do {
            self.codecContext = try Self.openDecoder(for: audioStream.pointee.codecpar)
        } catch {
            avformat_close_input(&openedFormatContext)
            throw error
        }
        self.formatContext = formatContext
        self.audioStreamIndex = audioStream.pointee.index
        self.timeBase = audioStream.pointee.time_base
        self.streamDuration = audioStream.pointee.duration
    }

    func hasKnownDuration(upTo budget: AudioTime) -> Bool {
        if streamDuration > 0 {
            return Double(streamDuration) * av_q2d(timeBase) <= budget.seconds
        }
        let containerDuration = formatContext.pointee.duration
        return containerDuration > 0 && Double(containerDuration) / Double(AV_TIME_BASE) <= budget.seconds
    }

    deinit {
        var codecContext: UnsafeMutablePointer<AVCodecContext>? = codecContext
        avcodec_free_context(&codecContext)
        var formatContext: UnsafeMutablePointer<AVFormatContext>? = formatContext
        avformat_close_input(&formatContext)
    }

    private static func openDecoder(
        for parameters: UnsafeMutablePointer<AVCodecParameters>
    ) throws(MediaDecodingError) -> UnsafeMutablePointer<AVCodecContext> {
        guard let decoder = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw .decoderUnavailable(codecName: String(cString: avcodec_get_name(parameters.pointee.codec_id)))
        }
        guard let context = avcodec_alloc_context3(decoder) else {
            throw .decoderSetupFailed(FFmpegError(code: -ENOMEM))
        }
        var status = avcodec_parameters_to_context(context, parameters)
        if status >= 0 {
            status = avcodec_open2(context, decoder, nil)
        }
        guard status >= 0 else {
            var failedContext: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&failedContext)
            throw .decoderSetupFailed(FFmpegError(code: status))
        }
        return context
    }
}
