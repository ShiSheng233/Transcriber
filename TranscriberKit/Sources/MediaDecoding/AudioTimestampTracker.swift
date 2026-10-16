/// Finds frames whose timestamp does not continue from the previous frame,
/// using the same rule as the resampler's correction (`aresample=async=1`).
///
/// Some files have holes: one AAC packet claims seconds of time but holds
/// 64 ms of sound. Joining the frames end to end, as the original does,
/// moves every subtitle after a hole too early (WhisperJAV measured 10 s by
/// the last hour of a film; docs/measurements/v1.9.4/MEASUREMENTS_v194_REQ1_REQ2.md §1).
struct AudioTimestampTracker {
    /// swresample's `min_hard_comp` default: smaller jumps are timestamp
    /// rounding, not holes.
    static let minimumJumpSeconds = 0.1

    private var expectedStartSeconds: Double?

    /// The jump in seconds before this frame, or `nil` if it continues the audio.
    mutating func jump(atFrameStartingAt startSeconds: Double, durationSeconds: Double) -> Double? {
        defer { expectedStartSeconds = startSeconds + durationSeconds }
        guard let expectedStartSeconds else {
            return nil  // the first frame sets the origin, like aresample without first_pts
        }
        let jump = startSeconds - expectedStartSeconds
        return abs(jump) > Self.minimumJumpSeconds ? jump : nil
    }
}
