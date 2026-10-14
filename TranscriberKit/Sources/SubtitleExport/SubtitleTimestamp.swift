import TranscriberCore

/// Timestamp text for each format. All parts are truncated, never rounded,
/// as in the original `SubWriter`.
enum SubtitleTimestamp {
    /// `HH:MM:SS<separator>mmm`, hours padded to two digits but not limited.
    static func hoursMinutesSeconds(_ time: AudioTime, millisecondSeparator: String) -> String {
        let parts = TimeParts(time)
        return "\(pad(parts.hours, 2)):\(pad(parts.minutes, 2)):\(pad(parts.seconds, 2))"
            + "\(millisecondSeparator)\(pad(parts.milliseconds, 3))"
    }

    /// LRC `MM:SS.cc`: total minutes (may exceed 99), centiseconds.
    static func lrc(_ time: AudioTime) -> String {
        let totalMilliseconds = time.milliseconds
        let minutes = totalMilliseconds / 60_000
        let seconds = totalMilliseconds % 60_000 / 1_000
        let centiseconds = totalMilliseconds % 1_000 / 10
        return "\(pad(minutes, 2)):\(pad(seconds, 2)).\(pad(centiseconds, 2))"
    }

    /// ASS `H:MM:SS.cc`.
    static func ass(_ time: AudioTime) -> String {
        let parts = TimeParts(time)
        return "\(parts.hours):\(pad(parts.minutes, 2)):\(pad(parts.seconds, 2)).\(pad(parts.milliseconds / 10, 2))"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private struct TimeParts {
        let hours: Int
        let minutes: Int
        let seconds: Int
        let milliseconds: Int

        init(_ time: AudioTime) {
            let total = time.milliseconds
            hours = total / 3_600_000
            minutes = total % 3_600_000 / 60_000
            seconds = total % 60_000 / 1_000
            milliseconds = total % 1_000
        }
    }
}
