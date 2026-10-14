import Foundation
import TranscriberCore

/// Aegisub's time notation, "0:01:02.50" (hours, minutes, seconds, centiseconds).
enum SubtitleTimeFormat {
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
        let numbers = fields.map { Double($0) }
        guard numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else {
            return nil
        }
        let seconds = numbers.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return AudioTime(milliseconds: Int((seconds * 1_000).rounded()))
    }
}
