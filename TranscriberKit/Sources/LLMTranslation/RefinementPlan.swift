import TranscriberCore

/// How lines are grouped for the language model: scenes, each a run of
/// batches sent one after another so every batch can carry the summaries of
/// the ones before it (WhisperJAV's PySubtrans setup,
/// whisperjav/translate/core.py). Different scenes run at the same time.
struct RefinementPlan: Equatable {
    /// Line indices of one request, consecutive in the subtitles.
    typealias Batch = [Int]

    let scenes: [[Batch]]

    var batchCount: Int {
        scenes.reduce(0) { $0 + $1.count }
    }

    /// - Parameters:
    ///   - lineIndices: the lines to send, ascending; usually all of them.
    ///   - sceneGap: a pause this long between two lines starts a new scene.
    ///   - maximumBatchesPerScene: longer scenes are split so that a film
    ///     without long pauses still runs several requests at once.
    init(
        lineIndices: [Int],
        of segments: [TimedText],
        batchSize: Int,
        sceneGap: AudioTime,
        maximumBatchesPerScene: Int
    ) {
        var runs: [[Int]] = []
        for index in lineIndices {
            if let previous = runs.last?.last,
               index == previous + 1,
               segments[index].start - segments[previous].end < sceneGap {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        let batchLimit = max(batchSize, 1)
        let sceneLimit = max(maximumBatchesPerScene, 1)
        scenes = runs.flatMap { run in
            let batches = stride(from: 0, to: run.count, by: batchLimit).map { Array(run[$0..<min($0 + batchLimit, run.count)]) }
            return stride(from: 0, to: batches.count, by: sceneLimit).map { Array(batches[$0..<min($0 + sceneLimit, batches.count)]) }
        }
    }
}
