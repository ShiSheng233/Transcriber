/// Repairs a line that loops ("あなたが好きあなたが好きあなたが好き…"),
/// judging the line itself rather than its whole 30 s window, so the rest of
/// the window's lines stay. Works on characters, since Japanese has no spaces
/// and the compression ratio of a short line means little.
public enum LineLoopRepair {
    /// Shorter lines are left alone.
    static let minimumLength = 12
    /// Units up to this many characters are looked for.
    static let maximumUnitLength = 10
    /// A unit repeated back to back over more than this share of the line is a loop.
    static let loopShare = 0.5
    /// Fewer distinct characters than this share of the length is a loop too.
    static let minimumDistinctShare = 0.3
    /// What a loop without a clear unit is cut to.
    static let unclearLoopKeptLength = 10
    /// Copies of the unit kept, so the line still reads as repeated speech.
    static let keptCopies = 2

    /// The repaired line: up to two copies of the looping unit and "…";
    /// the text unchanged when it does not loop.
    public static func repaired(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count >= minimumLength else {
            return text
        }
        if let loop = longestLoop(in: characters), Double(loop.length) > Double(characters.count) * loopShare {
            let kept = characters[..<(loop.start + loop.unit * keptCopies)]
            return String(kept) + "…"
        }
        if Double(Set(characters).count) < Double(characters.count) * minimumDistinctShare {
            return String(characters.prefix(unclearLoopKeptLength)) + "…"
        }
        return text
    }

    /// The longest back-to-back repetition of any unit up to the maximum length.
    private static func longestLoop(in characters: [Character]) -> (start: Int, unit: Int, length: Int)? {
        var best: (start: Int, unit: Int, length: Int)?
        for unit in 1...min(maximumUnitLength, characters.count / 2) {
            var start = 0
            while start + unit < characters.count {
                var end = start + unit
                while end < characters.count, characters[end] == characters[end - unit] {
                    end += 1
                }
                let length = end - start
                if length >= unit * 2, length > best?.length ?? 0 {
                    best = (start, unit, length)
                }
                start = max(end - unit + 1, start + 1)
            }
        }
        return best
    }
}
