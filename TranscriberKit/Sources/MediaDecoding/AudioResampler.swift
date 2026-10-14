import libavutil
import libswresample

/// Converts decoded frames to 16 kHz mono signed 16-bit samples with
/// libswresample's default options, like PyAV's `AudioResampler(format="s16",
/// layout="mono", rate=16000)` in the original, then to `Float` / 32768.
final class AudioResampler {
    static let outputSampleRate: Int32 = 16_000
    private static let int16Scale: Float = 32_768

    private var context: OpaquePointer?
    private var inputFormat: InputFormat?

    deinit {
        swr_free(&context)
    }

    /// Appends the resampled frame to `output`.
    func resample(_ frame: UnsafeMutablePointer<AVFrame>, into output: inout [Float]) throws(MediaDecodingError) {
        let format = InputFormat(frame)
        if format != inputFormat {
            // Mid-stream format change: drain the old converter, start a new one.
            try flush(into: &output)
            try configure(for: frame)
            inputFormat = format
        }
        let input = UnsafeRawPointer(frame.pointee.extended_data)?.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        try convert(input: input, inputSampleCount: frame.pointee.nb_samples, into: &output)
    }

    /// Emits the samples still buffered inside the converter.
    func flush(into output: inout [Float]) throws(MediaDecodingError) {
        guard context != nil else {
            return
        }
        try convert(input: nil, inputSampleCount: 0, into: &output)
    }

    private func configure(for frame: UnsafeMutablePointer<AVFrame>) throws(MediaDecodingError) {
        swr_free(&context)
        var inputLayout = AVChannelLayout()
        if frame.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&inputLayout, frame.pointee.ch_layout.nb_channels)
        } else {
            av_channel_layout_copy(&inputLayout, &frame.pointee.ch_layout)
        }
        defer { av_channel_layout_uninit(&inputLayout) }
        var monoLayout = AVChannelLayout()
        av_channel_layout_default(&monoLayout, 1)
        defer { av_channel_layout_uninit(&monoLayout) }

        var status = swr_alloc_set_opts2(
            &context,
            &monoLayout, AV_SAMPLE_FMT_S16, Self.outputSampleRate,
            &inputLayout, AVSampleFormat(frame.pointee.format), frame.pointee.sample_rate,
            0, nil
        )
        if status >= 0 {
            status = swr_init(context)
        }
        guard status >= 0 else {
            throw .resamplerSetupFailed(FFmpegError(code: status))
        }
    }

    private func convert(
        input: UnsafePointer<UnsafePointer<UInt8>?>?,
        inputSampleCount: Int32,
        into output: inout [Float]
    ) throws(MediaDecodingError) {
        while true {
            let capacity = max(swr_get_out_samples(context, inputSampleCount), 1)
            var samples = [Int16](repeating: 0, count: Int(capacity))
            let produced = samples.withUnsafeMutableBytes { buffer in
                var planes: [UnsafeMutablePointer<UInt8>?] = [buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)]
                return swr_convert(context, &planes, capacity, input, inputSampleCount)
            }
            guard produced >= 0 else {
                throw .decodingFailed(FFmpegError(code: produced))
            }
            output.append(contentsOf: samples.prefix(Int(produced)).map { Float($0) / Self.int16Scale })
            // With input, one call converts everything; when flushing, repeat until drained.
            if input != nil || produced == 0 {
                return
            }
        }
    }

    private struct InputFormat: Equatable {
        let sampleFormat: Int32
        let sampleRate: Int32
        let channelCount: Int32
        let channelOrder: UInt32
        let channelMask: UInt64

        init(_ frame: UnsafeMutablePointer<AVFrame>) {
            sampleFormat = frame.pointee.format
            sampleRate = frame.pointee.sample_rate
            channelCount = frame.pointee.ch_layout.nb_channels
            channelOrder = frame.pointee.ch_layout.order.rawValue
            channelMask = frame.pointee.ch_layout.order == AV_CHANNEL_ORDER_NATIVE ? frame.pointee.ch_layout.u.mask : 0
        }
    }
}
