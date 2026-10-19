import AVFoundation
import Foundation
import Testing
import TranscriberCore
@testable import MediaDecoding

/// Frame times and keyframes read from small H.264 movies written for each
/// test with AVAssetWriter, in the test's own temporary folder.
final class VideoFrameReaderTests {
    private static let timescale: CMTimeScale = 600
    private static let frameSize = 64
    /// The encoder places a keyframe at least this often.
    private static let keyframeInterval = 10

    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoFrameReaderTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a movie with a frame at each of `ticks` (in 1/600 s).
    private func writeMovie(ticks: [Int64]) async throws -> URL {
        let url = directory.appendingPathComponent("movie.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.frameSize,
            AVVideoHeightKey: Self.frameSize,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: Self.keyframeInterval,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.mediaTimeScale = Self.timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (index, tick) in ticks.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(adaptor.append(try Self.pixelBuffer(shade: UInt8(index * 7 % 256)), withPresentationTime: CMTime(value: tick, timescale: Self.timescale)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private static func pixelBuffer(shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, frameSize, frameSize, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(shade), CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func expectTimes(_ frames: VideoFrames, _ ticks: [Int64]) {
        #expect(frames.frameCount == ticks.count)
        for (time, tick) in zip(frames.frameTimes, ticks) {
            #expect(abs(time.samples - AudioTime(seconds: Double(tick) / Double(Self.timescale)).samples) <= 1)
        }
    }

    @Test func readsEveryFrameAndTheKeyframes() async throws {
        // 10 fps for three seconds.
        let ticks = (0..<30).map { Int64($0 * 60) }
        let frames = try #require(try VideoFrameReader().frames(at: try await writeMovie(ticks: ticks)))
        expectTimes(frames, ticks)
        #expect(frames.keyframes.first == 0)
        let gaps = zip(frames.keyframes.dropFirst(), frames.keyframes).map { $0 - $1 }
        #expect(frames.keyframes.count >= 3 && gaps.allSatisfy { $0 <= Self.keyframeInterval })
    }

    @Test func aVariableFrameRateKeepsEachFramesOwnTime() async throws {
        // 10 fps, then 20 fps.
        let ticks: [Int64] = [0, 60, 120, 180, 210, 240, 270, 300, 330]
        let frames = try #require(try VideoFrameReader().frames(at: try await writeMovie(ticks: ticks)))
        expectTimes(frames, ticks)
    }

    @Test func audioHasNoFrames() throws {
        let url = try #require(Bundle.module.url(forResource: "stereo-44k", withExtension: "m4a", subdirectory: "Fixtures"))
        #expect(try VideoFrameReader().frames(at: url) == nil)
    }

    @Test func aMissingFileFailsToOpen() {
        #expect(throws: MediaDecodingError.self) {
            try VideoFrameReader().frames(at: directory.appendingPathComponent("missing.mp4"))
        }
    }
}
