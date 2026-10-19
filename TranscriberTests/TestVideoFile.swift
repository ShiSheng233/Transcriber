import AVFoundation
import Foundation

/// A small H.264 movie written for a test and deleted with it.
final class TestVideoFile {
    let url: URL

    private static let frameSize = 64
    private static let timescale: CMTimeScale = 600

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriberTests-\(UUID().uuidString).mov")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// `frameCount` grey frames at `framesPerSecond`, a keyframe every `keyframeInterval` frames at most.
    func write(frameCount: Int, framesPerSecond: Int, keyframeInterval: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.frameSize,
            AVVideoHeightKey: Self.frameSize,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.mediaTimeScale = Self.timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let ticksPerFrame = Int64(Self.timescale) / Int64(framesPerSecond)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            let time = CMTime(value: Int64(index) * ticksPerFrame, timescale: Self.timescale)
            guard adaptor.append(try Self.greyFrame(), withPresentationTime: time) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
    }

    private static func greyFrame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, frameSize, frameSize, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
