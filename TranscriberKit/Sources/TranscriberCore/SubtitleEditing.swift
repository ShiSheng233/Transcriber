/// Editing operations on a subtitle list, after Aegisub's subtitle grid
/// commands. Each returns the new list (callers keep the old one for undo)
/// and, where it matters, which lines to select afterwards.
///
/// Indices outside the list are ignored. Lines stay sorted by start time
/// only where an operation moves times (`shift`, `setStart`); insertions go
/// where the user asked, as in Aegisub.
public enum SubtitleEditing {
    /// A new line's length when nothing bounds it (Aegisub `Timing/Default Duration`).
    public static let newLineDuration = AudioTime(milliseconds: 3_000)

    public struct Outcome: Equatable, Sendable {
        public let lines: [TimedText]
        /// The lines to select afterwards.
        public let selection: [Int]
    }

    /// An empty line right after `index`, starting where it ends and cut
    /// short at the next line's start (Aegisub's insert after).
    public static func insert(after index: Int, in lines: [TimedText]) -> Outcome {
        guard lines.indices.contains(index) else {
            let start = lines.last?.end ?? .zero
            return Outcome(lines: lines + [TimedText(start: start, end: start + newLineDuration, text: "")], selection: [lines.count])
        }
        let start = lines[index].end
        var end = start + newLineDuration
        if index + 1 < lines.count, lines[index + 1].start > start {
            end = min(end, lines[index + 1].start)
        }
        var result = lines
        result.insert(TimedText(start: start, end: end, text: ""), at: index + 1)
        return Outcome(lines: result, selection: [index + 1])
    }

    /// An empty line right before `index`, ending where it starts and cut
    /// short at the previous line's end.
    public static func insert(before index: Int, in lines: [TimedText]) -> Outcome {
        guard lines.indices.contains(index) else {
            return insert(after: lines.count - 1, in: lines)
        }
        let end = lines[index].start
        var start = end > newLineDuration ? end - newLineDuration : .zero
        if index > 0, lines[index - 1].end < end {
            start = max(start, lines[index - 1].end)
        }
        var result = lines
        result.insert(TimedText(start: start, end: end, text: ""), at: index)
        return Outcome(lines: result, selection: [index])
    }

    /// Aegisub "Make times continuous": each selected line starts where the
    /// previous line ends (`.start`), or ends where the next one starts
    /// (`.end`). A single line uses its neighbour.
    public enum ContinuousEdge: Sendable {
        case start
        case end
    }

    public static func makeContinuous(_ indices: [Int], changing edge: ContinuousEdge, in lines: [TimedText]) -> Outcome {
        let chosen = indices.filter(lines.indices.contains).sorted()
        var result = lines
        for index in chosen {
            switch edge {
            case .start where index > 0:
                result[index].start = min(result[index - 1].end, result[index].end)
            case .end where index + 1 < lines.count:
                result[index].end = max(result[index + 1].start, result[index].start)
            default:
                break
            }
        }
        return Outcome(lines: result, selection: chosen)
    }

    /// Copies of the lines, each right after its original.
    public static func duplicate(_ indices: [Int], in lines: [TimedText]) -> Outcome {
        let chosen = Set(indices.filter(lines.indices.contains))
        var result: [TimedText] = []
        var selection: [Int] = []
        for (index, line) in lines.enumerated() {
            result.append(line)
            if chosen.contains(index) {
                result.append(line)
                selection.append(result.count - 1)
            }
        }
        return Outcome(lines: result, selection: selection)
    }

    public static func delete(_ indices: [Int], in lines: [TimedText]) -> Outcome {
        let chosen = Set(indices)
        let result = lines.enumerated().filter { !chosen.contains($0.offset) }.map(\.element)
        let firstDeleted = indices.filter(lines.indices.contains).min() ?? 0
        return Outcome(lines: result, selection: result.isEmpty ? [] : [min(firstDeleted, result.count - 1)])
    }

    /// Aegisub "Join (concatenate)": the selected lines become one, from the
    /// first start to the last end, with their texts joined. Needs two or
    /// more lines; the first selected line's position is kept.
    public static func merge(_ indices: [Int], in lines: [TimedText]) -> Outcome {
        let chosen = indices.filter(lines.indices.contains).sorted()
        guard chosen.count >= 2, let first = chosen.first else {
            return Outcome(lines: lines, selection: chosen)
        }
        let parts = chosen.map { lines[$0] }
        let text = parts.map(\.text).reduce("") { joined($0, $1) }
        let merged = TimedText(
            start: parts.map(\.start).min() ?? parts[0].start,
            end: parts.map(\.end).max() ?? parts[0].end,
            text: text
        )
        var result = lines
        for index in chosen.reversed() {
            result.remove(at: index)
        }
        result.insert(merged, at: first)
        return Outcome(lines: result, selection: [first])
    }

    /// Aegisub "Split at cursor (estimate times)": the text before and after
    /// `textOffset` (in characters) become two lines, the time divided in
    /// proportion to their lengths.
    public static func split(_ index: Int, atCharacter textOffset: Int, in lines: [TimedText]) -> Outcome {
        guard lines.indices.contains(index) else {
            return Outcome(lines: lines, selection: [])
        }
        let line = lines[index]
        let characters = Array(line.text)
        let offset = min(max(textOffset, 0), characters.count)
        let before = String(characters[..<offset]).trimmingTrailingWhitespace
        let after = String(characters[offset...]).trimmingLeadingWhitespace
        let fraction = characters.isEmpty ? 0.5 : Double(offset) / Double(characters.count)
        let duration = line.end - line.start
        let middle = line.start + AudioTime(samples: Int((Double(duration.samples) * fraction).rounded()))
        var result = lines
        result[index] = TimedText(start: line.start, end: middle, text: before)
        result.insert(TimedText(start: middle, end: line.end, text: after), at: index + 1)
        return Outcome(lines: result, selection: [index + 1])
    }

    /// Moves the lines (all of them for an empty `indices`) by `offset`
    /// milliseconds, never before zero, then keeps the list sorted.
    public static func shift(_ indices: [Int], by offsetMilliseconds: Int, in lines: [TimedText]) -> Outcome {
        let chosen = indices.isEmpty ? Set(lines.indices) : Set(indices)
        let moved = lines.enumerated().map { index, line -> (line: TimedText, wasChosen: Bool) in
            guard chosen.contains(index) else {
                return (line, false)
            }
            let duration = line.end.milliseconds - line.start.milliseconds
            let start = max(line.start.milliseconds + offsetMilliseconds, 0)
            return (TimedText(start: AudioTime(milliseconds: start), end: AudioTime(milliseconds: start + duration), text: line.text), true)
        }
        let sorted = moved.enumerated().sorted { ($0.element.line.start, $0.offset) < ($1.element.line.start, $1.offset) }
        return Outcome(
            lines: sorted.map(\.element.line),
            selection: sorted.enumerated().filter { $0.element.element.wasChosen && !indices.isEmpty }.map(\.offset)
        )
    }

    /// New times for one line; the other end moves along if they would cross.
    public static func setTimes(_ index: Int, start: AudioTime? = nil, end: AudioTime? = nil, in lines: [TimedText]) -> Outcome {
        guard lines.indices.contains(index) else {
            return Outcome(lines: lines, selection: [])
        }
        var line = lines[index]
        if let start {
            line.start = start
            if line.end < start {
                line.end = start
            }
        }
        if let end {
            line.end = end
            if line.start > end {
                line.start = end
            }
        }
        var result = lines
        result[index] = line
        return Outcome(lines: result, selection: [index])
    }

    public static func setText(_ index: Int, to text: String, in lines: [TimedText]) -> Outcome {
        guard lines.indices.contains(index) else {
            return Outcome(lines: lines, selection: [])
        }
        var result = lines
        result[index].text = text
        return Outcome(lines: result, selection: [index])
    }

    /// Characters per second as Aegisub counts them (whitespace and
    /// punctuation ignored); `nil` where Aegisub leaves the cell blank: lines
    /// of 100 ms or less, or above 100 CPS.
    public static func charactersPerSecond(_ line: TimedText) -> Double? {
        let milliseconds = line.end.milliseconds - line.start.milliseconds
        guard milliseconds > 100 else {
            return nil
        }
        let count = line.text.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }.count
        let speed = Double(count) * 1_000 / Double(milliseconds)
        return speed > 100 ? nil : speed
    }

    /// Lines whose time overlaps `index`'s (Aegisub shows them in red).
    public static func overlapping(_ index: Int, in lines: [TimedText]) -> Set<Int> {
        guard lines.indices.contains(index) else {
            return []
        }
        let line = lines[index]
        return Set(lines.indices.filter { $0 != index && lines[$0].start < line.end && line.start < lines[$0].end })
    }

    /// The longest line of the text, for Aegisub's 40-character limit.
    public static func longestLineLength(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0
    }

    public static let characterLimit = 40

    /// A space between Latin words, nothing between CJK text.
    private static func joined(_ first: String, _ second: String) -> String {
        guard let last = first.last, let next = second.first else {
            return first + second
        }
        let needsSpace = !(isCJK(last) || isCJK(next)) && !last.isWhitespace && !next.isWhitespace
        return first + (needsSpace ? " " : "") + second
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3000...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        String(reversed().drop { $0.isWhitespace }.reversed())
    }

    var trimmingLeadingWhitespace: String {
        String(drop { $0.isWhitespace })
    }
}
