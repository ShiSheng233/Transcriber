import Foundation
import TranscriberCore

/// Video frame times on disk, so a film's keyframes are read once, even
/// across relaunches; found like waveforms (`MediaCacheFiles`). About 2 MB
/// per hour of 60 fps video.
public struct VideoFramesCache: Sendable {
    /// Files not used for this long are deleted when the cache is opened.
    public static let defaultLifetime = WaveformCache.defaultLifetime
    private static let fileExtension = "frames"
    /// Bumped when the file layout changes; older files are ignored.
    private static let formatVersion: UInt32 = 1

    private let directory: URL

    /// Creates the folder if needed and deletes expired files.
    public init(directory: URL, lifetime: Duration = Self.defaultLifetime) {
        self.directory = directory
        MediaCacheFiles.prepare(directory, fileExtensions: [Self.fileExtension], lifetime: lifetime)
    }

    /// The app's own folder in the user's Caches.
    public static var standardDirectory: URL {
        MediaCacheFiles.standardDirectory(named: "VideoFrames")
    }

    public func frames(for mediaURL: URL) -> VideoFrames? {
        guard let file = fileURL(for: mediaURL), let data = MediaCacheFiles.read(file) else {
            return nil
        }
        return Self.decode(data)
    }

    public func store(_ frames: VideoFrames, for mediaURL: URL) {
        guard let file = fileURL(for: mediaURL) else { return }
        try? Self.encode(frames).write(to: file, options: .atomic)
    }

    private func fileURL(for mediaURL: URL) -> URL? {
        MediaCacheFiles.url(for: mediaURL, in: directory, fileExtension: Self.fileExtension)
    }

    // MARK: Layout: version, frame count, keyframe count, frame times in samples, keyframe indices (little-endian)

    static func encode(_ frames: VideoFrames) -> Data {
        var data = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(formatVersion)
        append(Int64(frames.frameCount))
        append(Int64(frames.keyframes.count))
        frames.frameTimes.forEach { append(Int64($0.samples)) }
        frames.keyframes.forEach { append(Int64($0)) }
        return data
    }

    static func decode(_ data: Data) -> VideoFrames? {
        let headerSize = MemoryLayout<UInt32>.size + 2 * MemoryLayout<Int64>.size
        let valueSize = MemoryLayout<Int64>.size
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { bytes -> VideoFrames? in
            func value(at offset: Int) -> Int {
                Int(Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int64.self)))
            }
            let version = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let frameCount = value(at: 4)
            let keyframeCount = value(at: 12)
            guard version == formatVersion, frameCount >= 0, keyframeCount >= 0,
                  data.count == headerSize + (frameCount + keyframeCount) * valueSize else {
                return nil
            }
            let times = (0..<frameCount).map { AudioTime(samples: value(at: headerSize + $0 * valueSize)) }
            let keyframeOffset = headerSize + frameCount * valueSize
            let keyframes = (0..<keyframeCount).map { value(at: keyframeOffset + $0 * valueSize) }
            guard keyframes.allSatisfy(times.indices.contains) else { return nil }
            return VideoFrames(frameTimes: times, keyframeTimes: keyframes.map { times[$0] })
        }
    }
}
