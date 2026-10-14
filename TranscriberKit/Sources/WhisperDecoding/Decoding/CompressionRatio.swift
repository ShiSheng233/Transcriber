import zlib

/// faster-whisper's `get_compression_ratio`: UTF-8 length over the length of
/// `zlib.compress` (default level, zlib wrapper included). Repetitive text
/// compresses well, so a high ratio flags a looping decode.
enum CompressionRatio {
    static func of(_ text: String) -> Double {
        let bytes = Array(text.utf8)
        var compressedLength = compressBound(uLong(bytes.count))
        var compressed = [UInt8](repeating: 0, count: Int(compressedLength))
        let status = compress2(&compressed, &compressedLength, bytes, uLong(bytes.count), Z_DEFAULT_COMPRESSION)
        precondition(status == Z_OK, "zlib compress2 failed with \(status)")
        return Double(bytes.count) / Double(compressedLength)
    }
}
