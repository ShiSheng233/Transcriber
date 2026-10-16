/// Picks lines by what is wrong with them (Aegisub's Select Lines), so they
/// can be fixed, retranscribed or retranslated together.
public enum SubtitleSelection {
    public enum Criterion: Sendable {
        /// Faster to read than this many characters per second.
        case readingSpeedAbove(Double)
        /// Overlapping another line in time.
        case overlapping
        case durationBelow(AudioTime)
        case durationAbove(AudioTime)
        /// The text matches (the caller builds the matcher, e.g. a regex).
        case textMatching(@Sendable (String) -> Bool)
    }

    /// How the matches combine with the current selection.
    public enum Mode: Sendable, CaseIterable {
        case replace
        case add
        case subtract
        case intersect
    }

    public static func matching(_ criterion: Criterion, in lines: [TimedText]) -> [Int] {
        switch criterion {
        case .readingSpeedAbove(let limit):
            return lines.indices.filter { (SubtitleEditing.charactersPerSecond(lines[$0]) ?? 0) > limit }
        case .overlapping:
            return overlappingIndices(lines)
        case .durationBelow(let duration):
            return lines.indices.filter { lines[$0].end - lines[$0].start < duration }
        case .durationAbove(let duration):
            return lines.indices.filter { lines[$0].end - lines[$0].start > duration }
        case .textMatching(let matches):
            return lines.indices.filter { matches(lines[$0].text) }
        }
    }

    public static func combined(_ matches: [Int], with selection: [Int], mode: Mode) -> [Int] {
        let current = Set(selection)
        let found = Set(matches)
        let result: Set<Int> = switch mode {
        case .replace: found
        case .add: current.union(found)
        case .subtract: current.subtracting(found)
        case .intersect: current.intersection(found)
        }
        return result.sorted()
    }

    /// Every line overlapping some other line, by a sweep over start times.
    private static func overlappingIndices(_ lines: [TimedText]) -> [Int] {
        let order = lines.indices.sorted { (lines[$0].start, $0) < (lines[$1].start, $1) }
        var result = Set<Int>()
        var latest: Int?
        for index in order {
            if let latest, lines[latest].end > lines[index].start {
                result.insert(latest)
                result.insert(index)
            }
            if latest.map({ lines[index].end > lines[$0].end }) ?? true {
                latest = index
            }
        }
        return result.sorted()
    }
}
