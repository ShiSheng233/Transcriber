import Foundation
import libavcodec
import libavformat
import libavutil

/// Decodes the first audio stream of any supported media file to 16 kHz mono
/// `Float` samples, reproducing faster-whisper's `decode_audio` (PyAV/FFmpeg):
/// frames that fail with invalid data are skipped, and the resampler is
/// flushed at the end.
public struct MediaDecoder: Sendable {
    public init() {
        _ = Self.loggingConfigured
    }

    /// FFmpeg warns about recoverable stream details (e.g. trimming AAC
    /// priming samples); only errors are worth showing.
    private static let loggingConfigured: Void = {
        av_log_set_level(AV_LOG_ERROR)
    }()

    public func decodeAudio(at url: URL) throws -> [Float] {
        let input = try MediaInput(url: url)
        let resampler = AudioResampler()
        var samples: [Float] = []

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
            try decode(packet, with: input.codecContext, frame: frame, resampler: resampler, into: &samples)
        }

        // A nil packet drains the decoder's delayed frames.
        try decode(nil, with: input.codecContext, frame: frame, resampler: resampler, into: &samples)
        try resampler.flush(into: &samples)
        return samples
    }

    private func decode(
        _ packet: UnsafeMutablePointer<AVPacket>?,
        with codecContext: UnsafeMutablePointer<AVCodecContext>,
        frame: UnsafeMutablePointer<AVFrame>,
        resampler: AudioResampler,
        into samples: inout [Float]
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
            try resampler.resample(frame, into: &samples)
        }
    }
}

/// An opened media file with a decoder for its first audio stream (PyAV's `audio=0`).
private final class MediaInput {
    let formatContext: UnsafeMutablePointer<AVFormatContext>
    let codecContext: UnsafeMutablePointer<AVCodecContext>
    let audioStreamIndex: Int32

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
