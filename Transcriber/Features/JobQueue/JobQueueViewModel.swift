import Foundation
import JobQueue
import Observation
import TranscriberCore

/// The list of files and what is happening to them.
@Observable
final class JobQueueViewModel {
    struct Row: Identifiable, Equatable {
        enum Outcome: Equatable {
            case none
            case done
            case warning
            case failed
        }

        let id: UUID
        let fileName: String
        let modelName: String
        /// Full status, for the tooltip.
        let statusText: String
        /// Fits the sidebar: "whisper-ja-1.5B · 49%".
        let shortStatus: String
        let outcome: Outcome
        let fractionCompleted: Double?
        let canCancel: Bool
        let sourceURL: URL
        let outputURLs: [URL]
    }

    static let supportedExtensions: Set<String> = [
        "mp3", "wav", "flac", "m4a", "aac", "ogg", "opus", "wma", "mp4", "mkv", "avi", "mov", "webm", "flv", "wmv", "ts",
    ]

    private(set) var rows: [Row] = []
    private(set) var jobs: [Job] = []
    private(set) var selectedJobID: UUID?
    private(set) var isMissingModels = false

    private let queue: JobQueue
    private let settingsStore: SettingsStore
    private let apiKeyStore: APIKeyStore
    private let library: ModelLibrary
    private var snapshotTask: Task<Void, Never>?

    init(queue: JobQueue, settingsStore: SettingsStore, apiKeyStore: APIKeyStore, library: ModelLibrary) {
        self.queue = queue
        self.settingsStore = settingsStore
        self.apiKeyStore = apiKeyStore
        self.library = library
        snapshotTask = Task { [weak self] in
            for await jobs in await queue.snapshots() {
                self?.apply(jobs)
            }
        }
    }

    var selectedJob: Job? {
        jobs.first { $0.id == selectedJobID }
    }

    /// The selected file's name, or the app name.
    var windowTitle: String {
        selectedJob?.sourceURL.lastPathComponent ?? "Transcriber"
    }

    /// "ChickenRice v0.2 · 412 subtitles", or how many files are queued.
    var windowSubtitle: String {
        if let job = selectedJob {
            return job.segments.isEmpty
                ? job.model.displayName
                : String(localized: "\(job.model.displayName) · \(job.segments.count) subtitles")
        }
        return jobs.isEmpty ? "" : String(localized: "\(jobs.count) files")
    }

    var canStart: Bool {
        jobs.contains { $0.status == .queued }
    }

    var hasFinishedJobs: Bool {
        jobs.contains { $0.status.isFinished }
    }

    /// The models in the models folder, for the toolbar's model menu.
    var models: [RecognitionModel] {
        library.models
    }

    var selectedModelID: String? {
        library.selectedModel?.id
    }

    // MARK: Intents

    /// Files added from now on use this model.
    func selectModel(id: String) {
        settingsStore.update { $0.modelID = id }
    }

    /// Adds media files, and the media files inside folders, with the chosen
    /// model. With no model installed, nothing is added and `isMissingModels`
    /// asks the window to point the user to Settings.
    func addFiles(_ urls: [URL]) {
        let mediaFiles = urls.flatMap(Self.mediaFiles(in:))
        guard !mediaFiles.isEmpty else {
            return
        }
        library.reloadIfFolderChanged()
        guard let model = library.selectedModel else {
            isMissingModels = true
            return
        }
        Task { await queue.add(mediaFiles, model: model) }
    }

    func dismissMissingModels() {
        isMissingModels = false
    }

    func startQueue() {
        let configuration = settingsStore.settings.queueConfiguration(apiKeys: apiKeyStore)
        Task { await queue.start(configuration: configuration) }
    }

    func cancel(jobID: UUID) {
        Task { await queue.cancel(jobID) }
    }

    func remove(jobID: UUID) {
        Task { await queue.remove(jobID) }
    }

    func clearFinished() {
        Task { await queue.removeFinished() }
    }

    func select(jobID: UUID?) {
        selectedJobID = jobID
    }

    // MARK: Private

    private func apply(_ jobs: [Job]) {
        self.jobs = jobs
        rows = jobs.map(Self.row(for:))
        if let selectedJobID, !jobs.contains(where: { $0.id == selectedJobID }) {
            self.selectedJobID = nil
        }
    }

    private static func row(for job: Job) -> Row {
        Row(
            id: job.id,
            fileName: job.sourceURL.lastPathComponent,
            modelName: job.model.displayName,
            statusText: statusText(for: job),
            shortStatus: "\(job.model.displayName) · \(shortStatus(for: job))",
            outcome: outcome(of: job),
            fractionCompleted: job.status.fractionCompleted,
            canCancel: !job.status.isFinished,
            sourceURL: job.sourceURL,
            outputURLs: job.outputURLs
        )
    }

    private static func shortStatus(for job: Job) -> String {
        switch job.status {
        case .queued: String(localized: "Waiting")
        case .loadingModel: String(localized: "Loading model")
        case .decodingAudio: String(localized: "Reading audio")
        case .detectingSpeech: String(localized: "Finding speech")
        case .transcribing, .refining, .exporting:
            (job.status.fractionCompleted ?? 0).formatted(.percent.precision(.fractionLength(0)))
        case .completed: job.warning == nil ? String(localized: "Done") : String(localized: "Done with warning")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    private static func outcome(of job: Job) -> Row.Outcome {
        switch job.status {
        case .completed: job.warning == nil ? .done : .warning
        case .failed: .failed
        default: .none
        }
    }

    private static func statusText(for job: Job) -> String {
        if job.status == .completed, let warning = job.warning {
            return String(localized: "Done · \(warning)")
        }
        return switch job.status {
        case .queued: String(localized: "Waiting")
        case .loadingModel: String(localized: "Loading model…")
        case .decodingAudio: String(localized: "Reading audio…")
        case .detectingSpeech: String(localized: "Detecting speech…")
        case .transcribing(let completed, let total): String(localized: "Transcribing \(completed)/\(total)")
        case .refining(let completed, let total): String(localized: "Improving with LLM \(completed)/\(total)")
        case .exporting: String(localized: "Writing subtitles…")
        case .completed: String(localized: "Done")
        case .failed(let message): String(localized: "Failed: \(message)")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    private static func mediaFiles(in url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            return supportedExtensions.contains(url.pathExtension.lowercased()) ? [url] : []
        }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let files = (enumerator?.allObjects as? [URL]) ?? []
        return files
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
