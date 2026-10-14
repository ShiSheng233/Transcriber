import Foundation

/// One media file to subtitle, as the queue reports it.
public struct Job: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public var task: TranscriptionTask
    public var status: JobStatus
    /// Final segments once transcription finished.
    public var segments: [TimedText]
    /// Subtitle files written for this job.
    public var outputURLs: [URL]

    public init(id: UUID = UUID(), sourceURL: URL, task: TranscriptionTask) {
        self.id = id
        self.sourceURL = sourceURL
        self.task = task
        self.status = .queued
        self.segments = []
        self.outputURLs = []
    }
}

public enum JobStatus: Hashable, Sendable {
    case queued
    case loadingModel
    case decodingAudio
    case transcribing(completedChunks: Int, totalChunks: Int)
    case exporting
    case completed
    case failed(message: String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    /// 0...1 where it can be estimated.
    public var fractionCompleted: Double? {
        switch self {
        case .queued, .loadingModel: 0
        case .decodingAudio: 0.02
        case .transcribing(let completed, let total): 0.05 + 0.9 * Double(completed) / Double(max(total, 1))
        case .exporting: 0.97
        case .completed: 1
        case .failed, .cancelled: nil
        }
    }
}
