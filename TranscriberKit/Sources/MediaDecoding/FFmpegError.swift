import Darwin
import libavutil

/// An FFmpeg error code (`AVERROR(...)`), with the error macros Swift cannot import.
public struct FFmpegError: Error, Equatable, CustomStringConvertible {
    public let code: Int32

    static let tryAgain = FFmpegError(code: -EAGAIN)
    static let endOfFile = FFmpegError(code: -fourCharacterTag("EOF "))
    static let invalidData = FFmpegError(code: -fourCharacterTag("INDA"))

    public var description: String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        let message = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: message, as: UTF8.self)
    }

    /// `MKTAG(a, b, c, d)`: the first character in the lowest byte.
    private static func fourCharacterTag(_ tag: String) -> Int32 {
        tag.utf8.reversed().reduce(Int32(0)) { ($0 << 8) | Int32($1) }
    }
}
