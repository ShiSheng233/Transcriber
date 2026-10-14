import Foundation
import JobQueue
import Observation
import TranscriberCore

/// The list of files and what is happening to them.
@Observable
final class JobQueueViewModel {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let fileName: String
        let modelName: String
        let statusText: String
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

    var canStart: Bool {
        jobs.contains { $0.status == .queued }
    }

    var hasFinishedJobs: Bool {
        jobs.contains { $0.status.isFinished }
    }

    // MARK: Intents

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
        let configuration = settingsStore.settings.queueConfiguration(apiKey: apiKeyStore.read())
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
            fractionCompleted: job.status.fractionCompleted,
            canCancel: !job.status.isFinished,
            sourceURL: job.sourceURL,
            outputURLs: job.outputURLs
        )
    }

    private static func statusText(for job: Job) -> String {
        if job.status == .completed, let warning = job.warning {
            return String(localized: "Done · \(warning)")
        }
        return switch job.status {
        case .queued: String(localized: "Waiting")
        case .loadingModel: String(localized: "Loading model…")
        case .decodingAudio: String(localized: "Reading audio…")
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
