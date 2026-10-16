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

    /// One minute of audio.
    public static let defaultChunkSize = 60 * AudioTime.sampleRate

    private func decode(at url: URL, deliveringEvery chunkSize: Int?, consume: ([Float]) throws -> Void) throws -> Output {
        let input = try MediaInput(url: url)
        var output = Output(resampler: AudioResampler(followsTimestamps: timestampHandling == .followTimestamps), timeBase: input.timeBase)

        guard let packet = av_packet_alloc(), let frame = av_frame_alloc() else {
            throw MediaDecodingError.decodingFailed(FFmpegError(code: -ENOMEM))
        }
        var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
        var framePointer: UnsafeMutablePointer<AVFrame>? = frame
        defer {
            av_packet_free(&packetPointer)
            av_frame_free(&framePointer)
        }

        while av_read_frame(input.formatContext, packet) >= 0 {
            defer { av_packet_unref(packet) }
            try Task.checkCancellation()
            guard packet.pointee.stream_index == input.audioStreamIndex else {
                continue
            }
            try decode(packet, with: input.codecContext, frame: frame, into: &output)
            if let chunkSize, output.samples.count >= chunkSize {
                try consume(output.takeSamples())
            }
        }

        // A nil packet drains the decoder's delayed frames.
        try decode(nil, with: input.codecContext, frame: frame, into: &output)
        try output.resampler.flush(into: &output.samples)
        if chunkSize != nil, !output.samples.isEmpty {
            try consume(output.takeSamples())
        }
        return output
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

        mutating func append(_ frame: UnsafeMutablePointer<AVFrame>) throws(MediaDecodingError) {
            let timestamp = frame.pointee.best_effort_timestamp
            if timestamp != AudioResampler.noTimestamp, frame.pointee.sample_rate > 0 {
                let startSeconds = Double(timestamp) * av_q2d(timeBase)
                let durationSeconds = Double(frame.pointee.nb_samples) / Double(frame.pointee.sample_rate)
                if let jump = timestampTracker.jump(atFrameStartingAt: startSeconds, durationSeconds: durationSeconds) {
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
        into output: inout Output
    ) throws {
        let sendStatus = avcodec_send_packet(codecContext, packet)
        if sendStatus == FFmpegError.invalidData.code {
            return
        }
        guard sendStatus >= 0 || sendStatus == FFmpegError.endOfFile.code else {
            throw MediaDecodingError.decodingFailed(FFmpegError(code: sendStatus))
        }

        while true {
            let receiveStatus = avcodec_receive_frame(codecContext, frame)
            if receiveStatus == FFmpegError.tryAgain.code || receiveStatus == FFmpegError.endOfFile.code {
                return
            }
            if receiveStatus == FFmpegError.invalidData.code {
                continue
            }
            guard receiveStatus >= 0 else {
                throw MediaDecodingError.decodingFailed(FFmpegError(code: receiveStatus))
            }
            defer { av_frame_unref(frame) }
            try output.append(frame)
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

        do {
            self.codecContext = try Self.openDecoder(for: audioStream.pointee.codecpar)
        } catch {
            avformat_close_input(&openedFormatContext)
            throw error
        }
        self.formatContext = formatContext
        self.audioStreamIndex = audioStream.pointee.index
        self.timeBase = audioStream.pointee.time_base
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
