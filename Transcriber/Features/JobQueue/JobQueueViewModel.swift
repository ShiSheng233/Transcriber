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


    private(set) var rows: [Row] = []
    private(set) var jobs: [Job] = []
    private(set) var selectedJobID: UUID?
    private(set) var isMissingModels = false
    /// Media files with subtitles next to them, waiting for the user to
    /// choose between translating those subtitles and transcribing again.
    private(set) var pendingSubtitleChoice: FileIntake?
    /// Jobs whose subtitles were edited since they were last written.
    private(set) var unsavedJobIDs: Set<UUID> = []

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
            let task = Self.taskName(for: job)
            return job.segments.isEmpty ? task : String(localized: "\(task) · \(job.segments.count) subtitles")
        }
        return jobs.isEmpty ? "" : String(localized: "\(jobs.count) files")
    }

    /// A file is being worked on.
    var isRunning: Bool {
        jobs.contains { !$0.status.isFinished && $0.status != .queued }
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

    enum SubtitleChoice {
        case translateSubtitles
        case transcribe
        case cancel
    }

    /// Adds media files to transcribe with the chosen model and subtitle
    /// files to translate, also from inside folders. Media files that already
    /// have subtitles wait in `pendingSubtitleChoice` for the user. With no
    /// speech model installed, `isMissingModels` asks the window to point to
    /// Settings.
    func addFiles(_ urls: [URL]) {
        let intake = FileIntake(urls)
        if intake.mediaWithSubtitles.isEmpty {
            enqueue(intake)
        } else {
            pendingSubtitleChoice = intake
        }
    }

    func resolveSubtitleChoice(_ choice: SubtitleChoice) {
        guard var intake = pendingSubtitleChoice else {
            return
        }
        pendingSubtitleChoice = nil
        switch choice {
        case .translateSubtitles:
            intake.subtitlesToTranslate += intake.mediaWithSubtitles.map {
                FileIntake.SubtitleFile(subtitleURL: $0.subtitleURL, mediaURL: $0.mediaURL)
            }
        case .transcribe:
            intake.mediaToTranscribe += intake.mediaWithSubtitles.map(\.mediaURL)
        case .cancel:
            return
        }
        intake.mediaWithSubtitles = []
        enqueue(intake)
    }

    private func enqueue(_ intake: FileIntake) {
        let subtitles = intake.subtitlesToTranslate.map { (subtitleURL: $0.subtitleURL, mediaURL: $0.mediaURL) }
        if !subtitles.isEmpty {
            Task { await queue.addSubtitleTranslations(subtitles) }
        }
        let media = intake.mediaToTranscribe
        guard !media.isEmpty else {
            return
        }
        library.reloadIfFolderChanged()
        guard let model = library.selectedModel else {
            isMissingModels = true
            return
        }
        Task { await queue.add(media, model: model) }
    }

    /// The editor changed a job's subtitles; they are written on Save.
    func updateSubtitles(of jobID: UUID, to lines: [TimedText]) {
        unsavedJobIDs.insert(jobID)
        Task { await queue.replaceSegments(of: jobID, with: lines) }
    }

    /// Writes the job's subtitle files again.
    func saveSubtitles(of jobID: UUID) async throws {
        _ = try await queue.saveSubtitles(of: jobID)
        unsavedJobIDs.remove(jobID)
    }

    func saveAllSubtitles() async throws {
        for jobID in unsavedJobIDs {
            try await saveSubtitles(of: jobID)
        }
    }

    func dismissMissingModels() {
        isMissingModels = false
    }

    func startQueue() {
        startQueue(usesLanguageModel: true)
    }

    /// `usesLanguageModel` false: the debug snapshot run, which must not
    /// send the user's lines to their LLM service.
    func startQueue(usesLanguageModel: Bool) {
        var configuration = settingsStore.settings.queueConfiguration(apiKeys: apiKeyStore)
        if !usesLanguageModel {
            configuration.llm = nil
        }
        Task { await queue.start(configuration: configuration) }
    }

    /// Interrupts the current file (it goes back to waiting) and stops.
    func stopQueue() {
        Task { await queue.stop() }
    }

    func cancel(jobID: UUID) {
        Task { await queue.cancel(jobID) }
    }

    func remove(jobID: UUID) {
        unsavedJobIDs.remove(jobID)
        Task { await queue.remove(jobID) }
    }

    /// Finished files leave the list, except those with unsaved edits.
    func clearFinished() {
        let removable = jobs.filter { $0.status.isFinished && !unsavedJobIDs.contains($0.id) }.map(\.id)
        Task {
            for jobID in removable {
                await queue.remove(jobID)
            }
        }
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
            modelName: taskName(for: job),
            statusText: statusText(for: job),
            shortStatus: "\(taskName(for: job)) · \(shortStatus(for: job))",
            outcome: outcome(of: job),
            fractionCompleted: job.status.fractionCompleted,
            canCancel: !job.status.isFinished,
            sourceURL: job.sourceURL,
            outputURLs: job.outputURLs
        )
    }

    /// The speech model, or "Translation" for an imported subtitle file.
    private static func taskName(for job: Job) -> String {
        job.model?.displayName ?? String(localized: "Translation")
    }

    private static func shortStatus(for job: Job) -> String {
        switch job.status {
        case .queued: String(localized: "Waiting")
        case .readingSubtitles: String(localized: "Reading subtitles")
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
        case .readingSubtitles: String(localized: "Reading subtitles…")
        case .detectingSpeech: String(localized: "Detecting speech…")
        case .transcribing(let completed, let total): String(localized: "Transcribing \(completed)/\(total)")
        case .refining(let completed, let total): String(localized: "Improving with LLM \(completed)/\(total)")
        case .exporting: String(localized: "Writing subtitles…")
        case .completed: String(localized: "Done")
        case .failed(let message): String(localized: "Failed: \(message)")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}
