import Foundation
import TranscriberCore

/// Aegisub's time notation, "0:01:02.50" (hours, minutes, seconds, centiseconds).
enum SubtitleTimeFormat {
    /// Longer than any media file; anything past it is a typo.
    private static let longestSeconds = 1_000.0 * 3_600

    static func string(_ time: AudioTime) -> String {
        let centiseconds = (time.milliseconds + 5) / 10
        return String(
            format: "%d:%02d:%02d.%02d",
            centiseconds / 360_000, centiseconds / 6_000 % 60, centiseconds / 100 % 60, centiseconds % 100
        )
    }

    /// Accepts "h:mm:ss.cc", "mm:ss.cc" or "ss.cc", with "," or "." and any
    /// number of fraction digits.
    static func time(from text: String) -> AudioTime? {
        let fields = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (1...3).contains(fields.count) else {
            return nil
        }
        let numbers = fields.compactMap { Double($0) }
        guard numbers.count == fields.count, numbers.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        // "inf" and "1e30" parse as numbers, but converting them to samples would trap.
        guard seconds <= longestSeconds else {
            return nil
        }
        return AudioTime(milliseconds: Int((seconds * 1_000).rounded()))
    }
}
