extension SubtitleEditing {
    /// Which times a shift moves (Aegisub's Shift Times "Affect").
    public enum TimeEdges: Sendable, CaseIterable {
        case both
        case start
        case end
    }

    /// Moves the chosen lines' times by `offset` (negative is earlier). Times
    /// never go below zero, and a line whose start would pass its end keeps
    /// zero length. The list stays sorted; the moved lines stay selected.
    public static func shift(_ indices: [Int], by offset: AudioTime, changing edges: TimeEdges, in lines: [TimedText]) -> Outcome {
        let chosen = Set(indices.filter(lines.indices.contains))
        let moved = lines.enumerated().map { index, line -> TimedText in
            guard chosen.contains(index) else {
                return line
            }
            var line = line
            switch edges {
            case .both:
                let duration = line.end - line.start
                line.start = max(line.start + offset, .zero)
                line.end = line.start + duration
            case .start:
                line.start = min(max(line.start + offset, .zero), line.end)
            case .end:
                line.end = max(line.end + offset, line.start)
            }
            return line
        }
        return sortedByStart(moved, keeping: Array(chosen))
    }
}
