import CryptoKit
import Foundation
import TranscriberCore

/// Waveforms on disk, so a file transcribed once opens in timing mode at
/// once, even after a relaunch. A waveform is found by the media file's
/// path, size and modification date, so a changed file is analyzed again.
/// About 3 MB per hour of audio; spectrograms, kept beside them once shown
/// (`WaveformCache+Spectrogram`), about 23 MB.
public struct WaveformCache: Sendable {
    /// Waveforms not used for this long are deleted when the cache is opened.
    public static let defaultLifetime: Duration = .seconds(30 * 24 * 60 * 60)
    private static let fileExtension = "waveform"
    /// Every kind of file the cache writes, for expiry.
    private static let fileExtensions: Set<String> = [fileExtension, spectrogramFileExtension]
    /// Bumped when the file layout changes; older files are ignored.
    private static let formatVersion: UInt32 = 1

    private let directory: URL

    /// Creates the folder if needed and deletes expired waveforms.
    public init(directory: URL, lifetime: Duration = Self.defaultLifetime) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.deleteFiles(in: directory, olderThan: Date.now.addingTimeInterval(-Double(lifetime.components.seconds)))
    }

    /// The app's own folder in the user's Caches.
    public static var standardDirectory: URL {
        URL.cachesDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Transcriber", isDirectory: true)
            .appendingPathComponent("Waveforms", isDirectory: true)
    }

    public func waveform(for mediaURL: URL) -> Waveform? {
        contents(for: mediaURL, fileExtension: Self.fileExtension).flatMap(Self.decode)
    }

    public func store(_ waveform: Waveform, for mediaURL: URL) {
        store(Self.encode(waveform), for: mediaURL, fileExtension: Self.fileExtension)
    }

    // MARK: Files

    /// What is stored for `mediaURL` under `fileExtension`.
    func contents(for mediaURL: URL, fileExtension: String) -> Data? {
        guard let file = fileURL(for: mediaURL, fileExtension: fileExtension), let data = try? Data(contentsOf: file) else {
            return nil
        }
        // Touched on use, so files in use do not expire.
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
        return data
    }

    func store(_ data: Data, for mediaURL: URL, fileExtension: String) {
        guard let file = fileURL(for: mediaURL, fileExtension: fileExtension) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func fileURL(for mediaURL: URL, fileExtension: String) -> URL? {
        // Read fresh each time: URL resource values are cached per URL.
        let attributes = try? FileManager.default.attributesOfItem(atPath: mediaURL.path)
        guard let size = attributes?[.size] as? Int, let modified = attributes?[.modificationDate] as? Date else {
            return nil
        }
        let identity = "\(mediaURL.standardizedFileURL.path)\n\(size)\n\(modified.timeIntervalSinceReferenceDate)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension(fileExtension)
    }

    private static func deleteFiles(in directory: URL, olderThan cutoff: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where fileExtensions.contains(file.pathExtension) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: Layout: version, sample count, bin count, peaks, levels (little-endian)

    static func encode(_ waveform: Waveform) -> Data {
        var data = Data()
        func append<Value>(_ value: Value) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        append(formatVersion.littleEndian)
        append(Int64(waveform.duration.samples).littleEndian)
        append(Int64(waveform.peaks.count).littleEndian)
        waveform.peaks.withUnsafeBytes { data.append(contentsOf: $0) }
        waveform.levels.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func decode(_ data: Data) -> Waveform? {
        let headerSize = MemoryLayout<UInt32>.size + 2 * MemoryLayout<Int64>.size
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { bytes -> Waveform? in
            let version = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let sampleCount = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: Int64.self))
            let binCount = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: Int64.self))
            let arrayBytes = Int(binCount) * MemoryLayout<Float>.size
            guard version == formatVersion, binCount >= 0, data.count == headerSize + 2 * arrayBytes else {
                return nil
            }
            let floats = bytes.baseAddress.map { UnsafeRawPointer($0) }
            guard let floats else { return nil }
            let peaks = [Float](UnsafeBufferPointer(start: floats.advanced(by: headerSize).assumingMemoryBound(to: Float.self), count: Int(binCount)))
            let levels = [Float](UnsafeBufferPointer(start: floats.advanced(by: headerSize + arrayBytes).assumingMemoryBound(to: Float.self), count: Int(binCount)))
            return Waveform(peaks: peaks, levels: levels, duration: AudioTime(samples: Int(sampleCount)))
        }
    }
}
