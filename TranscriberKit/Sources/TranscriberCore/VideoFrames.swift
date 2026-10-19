/// A video track's frames, for timing lines to the picture as Aegisub does:
/// when each frame appears and which frames are keyframes. Times count from
/// the start of the file, the timeline a player shows subtitles on.
///
/// A line is on screen for the frames shown at or after its start and before
/// its end (Aegisub's `agi::vfr::START` and `END`), so "the frame a start
/// shows on" is the first frame at or after it.
public struct VideoFrames: Hashable, Sendable {
    /// When each frame appears, ascending and without repeats: the frames'
    /// own timestamps, so a variable frame rate needs nothing special.
    public let frameTimes: [AudioTime]
    /// Indices into `frameTimes`, ascending.
    public let keyframes: [Int]
    /// Frames beyond either end are this far apart (the average).
    private let averageFrameSamples: Double

    /// Boundaries are placed on the coarsest of these grids that has a point
    /// between the two frames: ASS and LRC write centiseconds, SRT and VTT
    /// milliseconds, and every format truncates, so a time on the grid is
    /// written exactly and still lands on the frame meant.
    private static let boundaryGrids = [AudioTime(milliseconds: 10), AudioTime(milliseconds: 1)]

    /// Sorts the timestamps and drops repeats; a keyframe time that is not a
    /// frame time is ignored. `nil` for fewer than two frames: a still
    /// picture, such as an audio file's cover art, has no frame rate.
    public init?(frameTimes: [AudioTime], keyframeTimes: [AudioTime]) {
        var sorted: [AudioTime] = []
        for time in frameTimes.sorted() where time != sorted.last {
            sorted.append(time)
        }
        guard let first = sorted.first, let last = sorted.last, sorted.count >= 2 else {
            return nil
        }
        self.frameTimes = sorted
        averageFrameSamples = Double((last - first).samples) / Double(sorted.count - 1)
        let indices = Set(keyframeTimes).compactMap { time -> Int? in
            let index = Self.firstIndex(atOrAfter: time, in: sorted)
            return index < sorted.count && sorted[index] == time ? index : nil
        }
        keyframes = indices.sorted()
    }

    public var frameCount: Int {
        frameTimes.count
    }

    public var keyframeTimes: [AudioTime] {
        keyframes.map { frameTimes[$0] }
    }

    /// When frame `index` appears; past either end, the frames go on at the
    /// average rate (as Aegisub extrapolates).
    public func time(ofFrame index: Int) -> AudioTime {
        if frameTimes.indices.contains(index) {
            return frameTimes[index]
        }
        let (edge, offset) = index < 0 ? (frameTimes[0], index) : (frameTimes[frameCount - 1], index - (frameCount - 1))
        return edge + AudioTime(samples: Int((Double(offset) * averageFrameSamples).rounded()))
    }

    /// Aegisub `FrameAtTime(time, START)`: the first frame shown at or after
    /// `time`, the one a line starting then appears on.
    public func firstFrame(shownFrom time: AudioTime) -> Int {
        let index = Self.firstIndex(atOrAfter: time, in: frameTimes)
        guard index == 0 || index == frameCount else {
            return index
        }
        // Outside the frames: estimate, then settle on the exact one.
        var frame = index == 0
            ? -Int((Double((frameTimes[0] - time).samples) / averageFrameSamples).rounded(.down))
            : frameCount - 1 + Int((Double((time - frameTimes[frameCount - 1]).samples) / averageFrameSamples).rounded(.up))
        while self.time(ofFrame: frame - 1) >= time {
            frame -= 1
        }
        while self.time(ofFrame: frame) < time {
            frame += 1
        }
        return frame
    }

    /// Aegisub `FrameAtTime(time, END)`: the last frame shown before `time`,
    /// the last one a line ending then is on.
    public func lastFrame(shownBefore time: AudioTime) -> Int {
        firstFrame(shownFrom: time) - 1
    }

    /// Aegisub `TimeAtFrame(frame, START)`: a start that shows first on
    /// `frame`, halfway from the frame before (on a grid a format writes
    /// exactly), so a player's rounding cannot move it a frame.
    public func startTime(ofFrame index: Int) -> AudioTime {
        let previous = time(ofFrame: index - 1)
        let current = time(ofFrame: index)
        let middle = previous.samples + (current.samples - previous.samples) / 2
        let onGrid = Self.boundaryGrids.lazy.map { grid in
            AudioTime(samples: Int((Double(middle) / Double(grid.samples)).rounded()) * grid.samples)
        }.first { previous < $0 && $0 <= current }
        return max(onGrid ?? AudioTime(samples: middle), .zero)
    }

    /// Aegisub `TimeAtFrame(frame, END)`: an end whose last frame is `frame`.
    public func endTime(ofFrame index: Int) -> AudioTime {
        startTime(ofFrame: index + 1)
    }

    /// A start or end at `time` moved onto the frame boundary that keeps it
    /// on the same frames: the boundary before the first frame shown at or
    /// after it. Aligning twice changes nothing.
    public func alignedTime(_ time: AudioTime) -> AudioTime {
        startTime(ofFrame: firstFrame(shownFrom: time))
    }

    /// Aegisub's `get_closest_kf`: the keyframe nearest `frame`, the earlier
    /// on a tie, counting the last frame as one (as Aegisub's timing
    /// post-processor does, so ends can snap to the end of the video).
    public func closestKeyframe(to frame: Int) -> Int {
        let candidates = keyframes.last == frameCount - 1 ? keyframes : keyframes + [frameCount - 1]
        var low = 0
        var high = candidates.count
        while low < high {
            let middle = (low + high) / 2
            if candidates[middle] <= frame { low = middle + 1 } else { high = middle }
        }
        // candidates[low] is the first keyframe after `frame`.
        guard low < candidates.count else {
            return candidates[candidates.count - 1]
        }
        return low == 0 || candidates[low] - frame < frame - candidates[low - 1] ? candidates[low] : candidates[low - 1]
    }

    private static func firstIndex(atOrAfter time: AudioTime, in times: [AudioTime]) -> Int {
        var low = 0
        var high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] < time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
