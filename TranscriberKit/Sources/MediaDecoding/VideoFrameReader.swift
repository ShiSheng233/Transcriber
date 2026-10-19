import Foundation
import libavcodec
import libavformat
import libavutil
import TranscriberCore

/// Reads when each frame of a file's first video stream appears and which
/// frames are keyframes, from the container alone: the FFmpeg build decodes
/// only audio, and none is needed, since Matroska, MP4/MOV and AVI store each
/// frame's timestamp and keyframe flag (MPEG-TS flags keyframes only where
/// the broadcaster marked random access points).
///
/// FFmpeg rather than AVFoundation, so that every container the app accepts
/// works (AVFoundation cannot open Matroska) and the frames share the
/// demuxer the audio comes from. Every packet of the file is read, which
/// takes a few seconds for a film on an SSD; results are cached by
/// `VideoFramesLoader`.
public struct VideoFrameReader: Sendable {
    public init() {
        _ = Self.loggingConfigured
    }

    /// As in `MediaDecoder`: only errors are worth showing.
    private static let loggingConfigured: Void = {
        av_log_set_level(AV_LOG_ERROR)
    }()

    /// Picture streams that are not video: cover art and still images.
    private static let stillDispositions = Int32(AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_STILL_IMAGE)

    /// The frames, timed from the file's start (FFmpeg's `start_time`, where
    /// players put time zero); `nil` when the file has no video. Checks for
    /// cancellation between packets.
    public func frames(at url: URL) throws -> VideoFrames? {
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        let openStatus = avformat_open_input(&formatContext, url.path, nil, nil)
        guard openStatus >= 0, let context = formatContext else {
            throw MediaDecodingError.openFailed(url, FFmpegError(code: openStatus))
        }
        defer { avformat_close_input(&formatContext) }
        let streamInfoStatus = avformat_find_stream_info(context, nil)
        guard streamInfoStatus >= 0 else {
            throw MediaDecodingError.openFailed(url, FFmpegError(code: streamInfoStatus))
        }

        let streams = UnsafeBufferPointer(start: context.pointee.streams, count: Int(context.pointee.nb_streams)).compactMap { $0 }
        guard let video = streams.first(where: {
            $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO && $0.pointee.disposition & Self.stillDispositions == 0
        }) else {
            return nil
        }
        // The demuxer skips what it can of the other streams.
        for stream in streams where stream != video {
            stream.pointee.discard = AVDISCARD_ALL
        }

        let timeBase = av_q2d(video.pointee.time_base)
        let fileStart = context.pointee.start_time == AudioResampler.noTimestamp
            ? 0 : Double(context.pointee.start_time) / Double(AV_TIME_BASE)
        var frameTimes: [AudioTime] = []
        var keyframeTimes: [AudioTime] = []

        guard let packet = av_packet_alloc() else {
            throw MediaDecodingError.decodingFailed(FFmpegError(code: -ENOMEM))
        }
        var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetPointer) }

        while av_read_frame(context, packet) >= 0 {
            defer { av_packet_unref(packet) }
            try Task.checkCancellation()
            // Frames an edit list cuts are decoded but never shown.
            guard packet.pointee.stream_index == video.pointee.index, packet.pointee.flags & AV_PKT_FLAG_DISCARD == 0 else {
                continue
            }
            // AVI has decode times only, which are the display times there.
            let timestamp = packet.pointee.pts != AudioResampler.noTimestamp ? packet.pointee.pts : packet.pointee.dts
            guard timestamp != AudioResampler.noTimestamp else { continue }
            let time = AudioTime(seconds: Double(timestamp) * timeBase - fileStart)
            frameTimes.append(time)
            if packet.pointee.flags & AV_PKT_FLAG_KEY != 0 {
                keyframeTimes.append(time)
            }
        }
        return VideoFrames(frameTimes: frameTimes, keyframeTimes: keyframeTimes)
    }
}
