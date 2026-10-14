import Foundation

/// One file to subtitle, as the queue reports it.
public struct Job: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Transcribe a media file with a speech model.
        case transcription(RecognitionModel)
        /// Translate an existing subtitle file with the language model.
        case subtitleTranslation
        /// A subtitle file opened for editing; Save writes it back.
        case subtitleEditing
    }

    public let id: UUID
    /// The media file, or the subtitle file to translate.
    public let sourceURL: URL
    public let kind: Kind
    /// What the preview plays: the media file itself, or one found next to
    /// the subtitle file.
    public let mediaURL: URL?
    public var status: JobStatus
    /// While transcribing, each finished chunk's subtitles (a preview); the
    /// final subtitles once the job completed; empty if it failed.
    public var segments: [TimedText]
    /// Subtitle files written for this job.
    public var outputURLs: [URL]
    /// Set when the job finished but an optional step (the LLM) did not.
    public var warning: String?

    public init(id: UUID = UUID(), sourceURL: URL, model: RecognitionModel) {
        self.init(id: id, sourceURL: sourceURL, kind: .transcription(model), mediaURL: sourceURL)
    }

    /// `lines`: what to translate instead of the file's contents (edits not saved yet).
    public init(id: UUID = UUID(), subtitlesAt subtitleURL: URL, mediaURL: URL?, lines: [TimedText] = []) {
        self.init(id: id, sourceURL: subtitleURL, kind: .subtitleTranslation, mediaURL: mediaURL)
        segments = lines
    }

    /// Ready to edit at once; its own file is where Save writes.
    public init(id: UUID = UUID(), editing subtitleURL: URL, mediaURL: URL?, lines: [TimedText]) {
        self.init(id: id, sourceURL: subtitleURL, kind: .subtitleEditing, mediaURL: mediaURL)
        segments = lines
        outputURLs = [subtitleURL]
        status = .completed
    }

    private init(id: UUID, sourceURL: URL, kind: Kind, mediaURL: URL?) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = kind
        self.mediaURL = mediaURL
        self.status = .queued
        self.segments = []
        self.outputURLs = []
        self.warning = nil
    }
}

extension Job {
    /// The speech model of a transcription job.
    public var model: RecognitionModel? {
        if case .transcription(let model) = kind { model } else { nil }
    }
}

public enum JobStatus: Hashable, Sendable {
    case queued
    case readingSubtitles
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
        case .queued, .loadingModel, .readingSubtitles: 0
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
