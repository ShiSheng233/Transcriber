/// Finds each line's text before the language model changed it, for showing
/// the original next to the translation.
public enum SubtitleSources {
    /// The original of each line: the original line with the same times, or
    /// else the original lines whose middle falls inside it, joined by a
    /// line break; `nil` when none does (a line added by hand).
    public static func originals(of lines: [TimedText], in originalLines: [TimedText]) -> [String?] {
        guard !originalLines.isEmpty else {
            return Array(repeating: nil, count: lines.count)
        }
        var byTimes: [TimeKey: String] = [:]
        for line in originalLines where byTimes[TimeKey(line)] == nil {
            byTimes[TimeKey(line)] = line.text
        }
        let byMiddle = originalLines.sorted { $0.start < $1.start }
        return lines.map { line in
            if let exact = byTimes[TimeKey(line)] {
                return exact
            }
            let inside = byMiddle.filter { original in
                let middle = original.start + AudioTime(samples: (original.end - original.start).samples / 2)
                return line.start <= middle && middle < line.end
            }
            return inside.isEmpty ? nil : inside.map(\.text).joined(separator: "\n")
        }
    }

    private struct TimeKey: Hashable {
        let start: AudioTime
        let end: AudioTime

        init(_ line: TimedText) {
            start = line.start
            end = line.end
        }
    }
}
