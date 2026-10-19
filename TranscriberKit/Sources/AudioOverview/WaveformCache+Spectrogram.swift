import Foundation
import TranscriberCore

extension WaveformCache {
    static let spectrogramFileExtension = "spectrogram"
    /// Bumped when the spectrogram file layout or analysis changes; older files are ignored.
    private static let spectrogramFormatVersion: UInt32 = 1

    public func spectrogram(for mediaURL: URL) -> Spectrogram? {
        contents(for: mediaURL, fileExtension: Self.spectrogramFileExtension).flatMap(Self.decodeSpectrogram)
    }

    public func store(_ spectrogram: Spectrogram, for mediaURL: URL) {
        store(Self.encode(spectrogram), for: mediaURL, fileExtension: Self.spectrogramFileExtension)
    }

    // MARK: Layout: version, sample count, column count, band count, levels (little-endian)

    static func encode(_ spectrogram: Spectrogram) -> Data {
        var data = Data()
        func append<Value>(_ value: Value) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        append(spectrogramFormatVersion.littleEndian)
        append(Int64(spectrogram.duration.samples).littleEndian)
        append(Int64(spectrogram.columnCount).littleEndian)
        append(Int64(Spectrogram.bandCount).littleEndian)
        data.append(contentsOf: spectrogram.levels)
        return data
    }

    static func decodeSpectrogram(_ data: Data) -> Spectrogram? {
        let headerSize = MemoryLayout<UInt32>.size + 3 * MemoryLayout<Int64>.size
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { bytes -> Spectrogram? in
            let version = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let sampleCount = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: Int64.self))
            let columnCount = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: Int64.self))
            let bandCount = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 20, as: Int64.self))
            guard version == spectrogramFormatVersion, bandCount == Spectrogram.bandCount, columnCount >= 0, sampleCount >= 0,
                  data.count == headerSize + Int(columnCount) * Spectrogram.bandCount else {
                return nil
            }
            return Spectrogram(
                levels: [UInt8](bytes[headerSize...]),
                columnCount: Int(columnCount),
                duration: AudioTime(samples: Int(sampleCount))
            )
        }
    }
}
