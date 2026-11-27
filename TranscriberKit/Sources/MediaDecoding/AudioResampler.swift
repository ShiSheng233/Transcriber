import Accelerate
import libavutil
import libswresample

/// Converts decoded frames to 16 kHz mono signed 16-bit samples with
/// libswresample's default options, like PyAV's `AudioResampler(format="s16",
/// layout="mono", rate=16000)` in the original, then to `Float` / 32768.
///
/// When following timestamps it also works like FFmpeg's
/// `aresample=async=1`: a frame that starts more than 0.1 s after the
/// previous one ended gets silence before it, and one that starts that much
/// earlier loses the overlap. Smaller differences are left alone, so audio
/// without holes comes out sample for sample the same.
final class AudioResampler {
    static let outputSampleRate: Int32 = 16_000
    private static let int16ToFloatScale: Float = 1 / 32_768
    /// `aresample`'s `async=1`: fill and trim only, never stretch.
    private static let fillAndTrimOnly = 1.0

    private let followsTimestamps: Bool
    let maximumSamples: Int?
    private var context: OpaquePointer?
    private var inputFormat: InputFormat?
    private var resampledInt16: [Int16] = []
    private var resampledFloat: [Float] = []

    init(followsTimestamps: Bool, maximumSamples: Int? = nil) {
        self.followsTimestamps = followsTimestamps
        self.maximumSamples = maximumSamples
    }

    deinit {
        swr_free(&context)
    }

    /// Appends the resampled frame to `output`.
    /// - Parameter timeBase: the unit of the frame's timestamp.
    func resample(
        _ frame: UnsafeMutablePointer<AVFrame>,
        timeBase: AVRational,
        into output: inout [Float]
    ) throws {
        let format = InputFormat(frame)
        if format != inputFormat {
            // Mid-stream format change: drain the old converter, start a new one.
            try flush(into: &output)
            try configure(for: frame)
            inputFormat = format
        }
        let timestamp = frame.pointee.best_effort_timestamp
        if followsTimestamps, timestamp != Self.noTimestamp {
            // aresample's conversion: swr counts time in 1 / (input rate × output rate) s.
            let resamplerTimestamp = av_rescale(
                timestamp,
                Int64(timeBase.num) * Int64(Self.outputSampleRate) * Int64(frame.pointee.sample_rate),
                Int64(timeBase.den)
            )
            // Injects silence or drops samples when the jump is large enough.
            _ = swr_next_pts(context, resamplerTimestamp)
        }
        let input = UnsafeRawPointer(frame.pointee.extended_data)?.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        try convert(input: input, inputSampleCount: frame.pointee.nb_samples, into: &output)
    }

    /// Emits the samples still buffered inside the converter.
    func flush(into output: inout [Float]) throws {
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
        if status >= 0, followsTimestamps {
            status = av_opt_set_double(UnsafeMutableRawPointer(context), "async", Self.fillAndTrimOnly, 0)
        }
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
    ) throws {
        while true {
            let available = max(swr_get_out_samples(context, inputSampleCount), 1)
            let capacity = maximumSamples.map { Int32(min(Int(available), $0 - output.count + 1)) } ?? available
            if resampledInt16.count < Int(capacity) {
                resampledInt16.append(contentsOf: repeatElement(0, count: Int(capacity) - resampledInt16.count))
            }
            let produced = resampledInt16.withUnsafeMutableBytes { buffer in
                var plane = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return swr_convert(context, &plane, capacity, input, inputSampleCount)
            }
            guard produced >= 0 else {
                throw MediaDecodingError.decodingFailed(FFmpegError(code: produced))
            }
            if let maximumSamples, Int(produced) > maximumSamples - output.count {
                throw SampleLimitExceeded.exceeded
            }
            if produced > 0 {
                appendConvertedSamples(Int(produced), to: &output)
            }
            // With input, one call converts everything; when flushing, repeat until drained.
            if input != nil || produced == 0 {
                return
            }
        }
    }

    private func appendConvertedSamples(_ count: Int, to output: inout [Float]) {
        if resampledFloat.count < count {
            resampledFloat.append(contentsOf: repeatElement(0, count: count - resampledFloat.count))
        }
        resampledFloat.withUnsafeMutableBufferPointer { buffer in
            guard let destination = buffer.baseAddress else {
                preconditionFailure("The conversion buffer has space for \(count) samples")
            }
            let length = vDSP_Length(count)
            var scale = Self.int16ToFloatScale
            vDSP_vflt16(resampledInt16, 1, destination, 1, length)
            vDSP_vsmul(destination, 1, &scale, destination, 1, length)
            output.append(contentsOf: UnsafeBufferPointer(start: destination, count: count))
        }
    }

    enum SampleLimitExceeded: Error {
        case exceeded
    }

    /// `AV_NOPTS_VALUE`, which Swift cannot import.
    static let noTimestamp = Int64.min

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
