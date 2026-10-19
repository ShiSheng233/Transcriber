import AudioOverview
import Foundation
import Observation
import TranscriberCore

/// The shown file's video frames and keyframes, read in the background
/// while its video or waveform is shown (as Aegisub knows keyframes only
/// with a video open), for keyframe snapping, frame alignment and the
/// waveform's keyframe lines.
@Observable
final class VideoFramesViewModel {
    enum Availability: Equatable {
        /// Neither the video nor the waveform is shown, so nothing is read.
        case notRead
        case reading
        case available(VideoFrames)
        /// An audio file, or a video with only a still picture.
        case noVideo
        case failed
    }

    private(set) var availability = Availability.notRead
    /// Where each keyframe's lines start (between it and the frame before),
    /// as Aegisub marks them on its audio display.
    private(set) var keyframeBoundaries: [AudioTime] = []

    @ObservationIgnored private let loader: VideoFramesLoader
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(loader: VideoFramesLoader) {
        self.loader = loader
    }

    var frames: VideoFrames? {
        if case .available(let frames) = availability { frames } else { nil }
    }

    /// Why keyframes cannot be used yet; `nil` once they can.
    var unavailableReason: String? {
        switch availability {
        case .available: nil
        case .notRead: String(localized: "Show the video or turn on Timing Mode to read its keyframes.")
        case .reading: String(localized: "Reading the video's frames…")
        case .noVideo: String(localized: "This file has no video.")
        case .failed: String(localized: "The video's frames could not be read.")
        }
    }

    /// The keyframe boundaries from `start` through `end`, found by binary
    /// search: a film has thousands.
    func keyframeBoundaries(from start: AudioTime, through end: AudioTime) -> ArraySlice<AudioTime> {
        func firstIndex(where isInside: (AudioTime) -> Bool) -> Int {
            var low = 0
            var high = keyframeBoundaries.count
            while low < high {
                let middle = (low + high) / 2
                if isInside(keyframeBoundaries[middle]) { high = middle } else { low = middle + 1 }
            }
            return low
        }
        let first = firstIndex { $0 >= start }
        let past = max(firstIndex { $0 > end }, first)
        return keyframeBoundaries[first..<past]
    }

    /// Reads `url`'s frames unless they are already shown; `nil` forgets them.
    func show(_ url: URL?) {
        guard url != loadedURL else { return }
        loadTask?.cancel()
        loadedURL = url
        keyframeBoundaries = []
        guard let url else {
            availability = .notRead
            return
        }
        availability = .reading
        loadTask = Task { [loader] in
            let result: Availability
            do {
                result = try await loader.frames(for: url).map(Availability.available) ?? .noVideo
            } catch {
                result = .failed
            }
            guard !Task.isCancelled, loadedURL == url else { return }
            if case .available(let frames) = result {
                keyframeBoundaries = frames.keyframes.map(frames.startTime(ofFrame:))
            }
            availability = result
        }
    }
}
