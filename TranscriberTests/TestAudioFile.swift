import Foundation

/// Small media files written for a test and deleted with it.
final class TestAudioFile {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriberTests-\(UUID().uuidString).wav")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    private static let sampleRate = 16_000
    private static let toneFrequency = 440.0
    private static let toneAmplitude = 0.5

    /// 16-bit mono PCM: `silence` seconds, then a tone, then silence again.
    func writeTone(seconds: Double, between silence: Double) throws {
        let silentSamples = [Int16](repeating: 0, count: Int(silence * Double(Self.sampleRate)))
        let toneSamples = (0..<Int(seconds * Double(Self.sampleRate))).map { index in
            let phase = 2 * Double.pi * Self.toneFrequency * Double(index) / Double(Self.sampleRate)
            return Int16(sin(phase) * Self.toneAmplitude * Double(Int16.max))
        }
        try Self.wave(silentSamples + toneSamples + silentSamples).write(to: url)
    }

    /// Bytes no decoder reads as audio.
    func writeGarbage() throws {
        try Data("not audio".utf8).write(to: url)
    }

    private static func wave(_ samples: [Int16]) -> Data {
        let bytesPerSample = MemoryLayout<Int16>.size
        let dataSize = samples.count * bytesPerSample
        var data = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))  // fmt chunk size
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerSample))
        append(UInt16(bytesPerSample))
        append(UInt16(8 * bytesPerSample))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        for sample in samples {
            append(sample)
        }
        return data
    }
}
