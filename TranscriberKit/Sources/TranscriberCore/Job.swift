import Foundation

/// One media file to subtitle, as the queue reports it.
public struct Job: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public var model: RecognitionModel
    public var status: JobStatus
    /// Final segments once transcription finished.
    public var segments: [TimedText]
    /// Subtitle files written for this job.
    public var outputURLs: [URL]
    /// Set when the job finished but an optional step (the LLM) did not.
    public var warning: String?

    public init(id: UUID = UUID(), sourceURL: URL, model: RecognitionModel) {
        self.id = id
        self.sourceURL = sourceURL
        self.model = model
        self.status = .queued
        self.segments = []
        self.outputURLs = []
        self.warning = nil
    }
}

public enum JobStatus: Hashable, Sendable {
    case queued
    case loadingModel
    case decodingAudio
    case detectingSpeech
    case transcribing(completedChunks: Int, totalChunks: Int)
    case refining(completedBatches: Int, totalBatches: Int)
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
        case .detectingSpeech: 0.04
        case .transcribing(let completed, let total): 0.05 + 0.8 * Double(completed) / Double(max(total, 1))
        case .refining(let completed, let total): 0.85 + 0.1 * Double(completed) / Double(max(total, 1))
        case .exporting: 0.97
        case .completed: 1
        case .failed, .cancelled: nil
        }
    }
}
