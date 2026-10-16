import TranscriberCore

/// What Proofread Selected Lines sends to the language model and where the
/// corrections go.
///
/// A translated job keeps its Japanese in the lines from before the
/// language model: those are sent (all of them, so the context is Japanese
/// too) and the chosen lines' originals are corrected, found by their times;
/// the translations stay. A job that never went through the language model
/// shows the transcript itself, so its own lines are sent and corrected.
struct ProofreadingPlan: Equatable {
    enum Target: Equatable {
        /// The job's lines before the language model.
        case originals
        /// The lines as the editor has them.
        case lines
    }

    let target: Target
    /// What the language model gets, in order.
    let segments: [TimedText]
    /// The lines of `segments` to correct, ascending.
    let lineIndices: [Int]
    /// Chosen lines without an original of the same times (added by hand
    /// or retimed), which cannot be corrected.
    let skippedCount: Int

    /// - Parameters:
    ///   - lines: the job's lines as the editor has them.
    ///   - originals: the job's lines before the language model; empty if it never ran.
    init(chosen lineIndices: [Int], of lines: [TimedText], originals: [TimedText]) {
        let chosen = Array(Set(lineIndices.filter(lines.indices.contains))).sorted()
        guard !originals.isEmpty else {
            target = .lines
            segments = lines
            self.lineIndices = chosen
            skippedCount = 0
            return
        }
        var originalIndexByTimes: [JobQueue.TimeRange: Int] = [:]
        for (index, line) in originals.enumerated() where originalIndexByTimes[JobQueue.TimeRange(line)] == nil {
            originalIndexByTimes[JobQueue.TimeRange(line)] = index
        }
        let found = chosen.compactMap { originalIndexByTimes[JobQueue.TimeRange(lines[$0])] }
        target = .originals
        segments = originals
        self.lineIndices = Array(Set(found)).sorted()
        skippedCount = chosen.count - found.count
    }

    /// The answered lines whose text the model changed, by index into `segments`.
    func corrections(from answers: [Int: String]) -> [Int: String] {
        let chosen = Set(lineIndices)
        return answers.filter { index, text in
            chosen.contains(index) && segments.indices.contains(index) && segments[index].text != text
        }
    }
}
