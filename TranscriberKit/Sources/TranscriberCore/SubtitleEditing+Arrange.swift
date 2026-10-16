extension SubtitleEditing {
    /// Aegisub "Join (keep first)": the selected lines become one spanning
    /// them all, with the first line's text. Needs two or more lines.
    public static func mergeKeepingFirstText(_ indices: [Int], in lines: [TimedText]) -> Outcome {
        let chosen = indices.filter(lines.indices.contains).sorted()
        guard chosen.count >= 2, let first = chosen.first else {
            return Outcome(lines: lines, selection: chosen)
        }
        let merged = merge(chosen, in: lines)
        var result = merged.lines
        result[first].text = lines[first].text
        return Outcome(lines: result, selection: merged.selection)
    }

    /// Exchanges two lines' places in the list, times included (Aegisub
    /// "Swap"); exactly two lines.
    public static func swap(_ indices: [Int], in lines: [TimedText]) -> Outcome {
        let chosen = indices.filter(lines.indices.contains).sorted()
        guard chosen.count == 2 else {
            return Outcome(lines: lines, selection: chosen)
        }
        var result = lines
        result.swapAt(chosen[0], chosen[1])
        return Outcome(lines: result, selection: chosen)
    }

    /// All lines by start time, then end time; ties keep their order. The
    /// same lines stay selected wherever they land.
    public static func sortedByStart(_ lines: [TimedText], keeping selection: [Int]) -> Outcome {
        let order = lines.indices.sorted { (lines[$0].start, lines[$0].end, $0) < (lines[$1].start, lines[$1].end, $1) }
        let chosen = Set(selection)
        return Outcome(
            lines: order.map { lines[$0] },
            selection: order.enumerated().filter { chosen.contains($0.element) }.map(\.offset)
        )
    }

    /// Splits a line at a time inside it: the text before `textOffset`
    /// characters goes to the first part, the rest to the second. An offset
    /// at either end of the text gives both parts the whole text, as
    /// Aegisub's split at the video frame does.
    public static func split(_ index: Int, at time: AudioTime, atCharacter textOffset: Int, in lines: [TimedText]) -> Outcome {
        guard lines.indices.contains(index), lines[index].start < time, time < lines[index].end else {
            return Outcome(lines: lines, selection: lines.indices.contains(index) ? [index] : [])
        }
        let line = lines[index]
        let characters = Array(line.text)
        var first = line.text
        var second = line.text
        if textOffset > 0, textOffset < characters.count {
            first = String(characters[..<textOffset]).trimmingCharacters(in: \.isWhitespace, fromEnd: true)
            second = String(characters[textOffset...]).trimmingCharacters(in: \.isWhitespace, fromEnd: false)
        }
        var result = lines
        result[index] = TimedText(start: line.start, end: time, text: first)
        result.insert(TimedText(start: time, end: line.end, text: second), at: index + 1)
        return Outcome(lines: result, selection: [index + 1])
    }
}

private extension String {
    func trimmingCharacters(in isTrimmed: (Character) -> Bool, fromEnd: Bool) -> String {
        fromEnd ? String(reversed().drop(while: isTrimmed).reversed()) : String(drop(while: isTrimmed))
    }
}
