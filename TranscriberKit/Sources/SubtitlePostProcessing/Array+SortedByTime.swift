import TranscriberCore

extension Array where Element == TimedText {
    /// Sorted by (start, end), keeping the input order for ties like Python's
    /// stable `sorted`.
    func sortedByTime() -> [TimedText] {
        enumerated()
            .sorted { ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset) }
            .map(\.element)
    }
}
