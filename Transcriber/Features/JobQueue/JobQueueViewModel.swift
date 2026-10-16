import Foundation
import JobQueue
import LLMTranslation
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
    /// Jobs with lines at the language model again (one request each at a time).
    private(set) var retranslatingJobIDs: Set<UUID> = []
    /// Jobs with a stretch being transcribed again.
    private(set) var retranscribingJobIDs: Set<UUID> = []

    private let queue: JobQueue
    private let settingsStore: SettingsStore
    private let apiKeyStore: any APIKeyStoring
    private let library: ModelLibrary
    private var snapshotTask: Task<Void, Never>?

    init(queue: JobQueue, settingsStore: SettingsStore, apiKeyStore: any APIKeyStoring, library: ModelLibrary) {
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
            if job.kind == .subtitleEditing {
                return String(localized: "\(job.segments.count) subtitles")
            }
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
        case editSubtitles
        case translateSubtitles
        case transcribe
        case cancel
    }

    /// What a subtitle file is open for; switching moves between its jobs.
    enum SubtitleMode {
        case edit
        case translate
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
        let subtitles = intake.mediaWithSubtitles.map { (subtitleURL: $0.subtitleURL, mediaURL: Optional($0.mediaURL)) }
        switch choice {
        case .editSubtitles:
            intake.subtitleFiles += subtitles.map { FileIntake.SubtitleFile(subtitleURL: $0.subtitleURL, mediaURL: $0.mediaURL) }
        case .translateSubtitles:
            Task {
                await queue.addSubtitleTranslations(subtitles)
                startQueue()
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
        let subtitles = intake.subtitleFiles.map { (subtitleURL: $0.subtitleURL, mediaURL: $0.mediaURL) }
        if !subtitles.isEmpty {
            Task {
                // Ready at once: show the first one in the editor.
                if let first = await queue.openSubtitles(subtitles).first {
                    select(jobID: first)
                }
            }
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

    /// The language model is on and has a model to send lines to.
    var canUseLanguageModel: Bool {
        let llm = settingsStore.settings.llm
        return llm.isEnabled && !llm.model.isEmpty
    }

    /// Sends the chosen lines through the language model again; see
    /// `JobQueue.retranslate`.
    func retranslate(_ lineIndices: [Int], of lines: [TimedText], in jobID: UUID) async throws -> JobQueue.Retranslation {
        guard let llm = settingsStore.settings.queueConfiguration(apiKeys: apiKeyStore).llm else {
            throw JobQueueError.languageModelRequired
        }
        retranslatingJobIDs.insert(jobID)
        defer { retranslatingJobIDs.remove(jobID) }
        return try await queue.retranslate(lineIndices, of: lines, in: jobID, with: llm)
    }

    /// Whether the job has media to transcribe part of again.
    func canRetranscribe(jobID: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == jobID }) else {
            return false
        }
        return job.mediaURL != nil && (job.model != nil || library.selectedModel != nil)
            && !retranscribingJobIDs.contains(jobID) && !retranslatingJobIDs.contains(jobID)
    }

    /// Transcribes the time the chosen lines cover again (and translates
    /// the new lines when the job was translated); see `JobQueue.retranscribe`.
    /// A job without a model of its own uses the toolbar's.
    func retranscribe(_ lineIndices: [Int], of lines: [TimedText], in jobID: UUID) async throws -> JobQueue.Retranscription {
        let configuration = settingsStore.settings.queueConfiguration(apiKeys: apiKeyStore)
        retranscribingJobIDs.insert(jobID)
        defer { retranscribingJobIDs.remove(jobID) }
        return try await queue.retranscribe(
            lineIndices, of: lines, in: jobID, model: library.selectedModel, configuration: configuration
        )
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

    /// The mode of the job's subtitle file, or nil for a transcription.
    static func subtitleMode(of job: Job) -> SubtitleMode? {
        switch job.kind {
        case .subtitleEditing: .edit
        case .subtitleTranslation: .translate
        case .transcription: nil
        }
    }

    /// Edit: the file's editing job (opened if needed). Translate: its
    /// translation, or a new one of `lines` (the editor's current lines),
    /// started right away. A translation that failed is made again.
    func switchMode(of jobID: UUID, to mode: SubtitleMode, lines: [TimedText]) {
        guard let job = jobs.first(where: { $0.id == jobID }), let current = Self.subtitleMode(of: job), current != mode else {
            return
        }
        let file = (subtitleURL: job.sourceURL, mediaURL: job.mediaURL)
        let counterpart = jobs.last { other in
            other.sourceURL == job.sourceURL && Self.subtitleMode(of: other) == mode && other.status != .cancelled
        }
        if let counterpart, mode == .edit || !Self.isFailed(counterpart) {
            select(jobID: counterpart.id)
            return
        }
        Task {
            switch mode {
            case .edit:
                if let opened = await queue.openSubtitles([file]).first {
                    select(jobID: opened)
                }
            case .translate:
                if let created = await queue.addSubtitleTranslations([file], lines: lines).first {
                    select(jobID: created)
                    startQueue()
                }
            }
        }
    }

    private static func isFailed(_ job: Job) -> Bool {
        if case .failed = job.status { true } else { false }
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

    /// What the job's Model menu does, or nil when it cannot change: a
    /// waiting transcription switches models, a finished one is transcribed
    /// again (not while it has unsaved edits).
    enum ModelChange {
        case switchModel
        case transcribeAgain
    }

    func modelChange(for jobID: UUID) -> ModelChange? {
        guard let job = jobs.first(where: { $0.id == jobID }), job.model != nil else {
            return nil
        }
        if job.status == .queued {
            return .switchModel
        }
        return job.status.isFinished && !unsavedJobIDs.contains(jobID) ? .transcribeAgain : nil
    }

    struct ModelChoice: Equatable {
        let modelID: String
        let title: String
        /// The waiting job's current model.
        let isCurrent: Bool
    }

    /// The installed models for the job's Model menu.
    func modelChoices(for jobID: UUID) -> [ModelChoice] {
        let change = modelChange(for: jobID)
        let currentID = jobs.first { $0.id == jobID }?.model?.id
        return models.map { model in
            ModelChoice(modelID: model.id, title: model.displayName, isCurrent: change == .switchModel && model.id == currentID)
        }
    }

    /// Transcribes the file with another model; a finished file starts again.
    func changeModel(of jobID: UUID, toModelWithID modelID: String) {
        guard modelChange(for: jobID) != nil, let model = models.first(where: { $0.id == modelID }) else {
            return
        }
        Task {
            await queue.changeModel(of: jobID, to: model)
            startQueue()
        }
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

    /// The speech model, or what is being done with a subtitle file.
    private static func taskName(for job: Job) -> String {
        switch job.kind {
        case .transcription(let model): model.displayName
        case .subtitleTranslation: String(localized: "Translation")
        case .subtitleEditing: String(localized: "Subtitles")
        }
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
        case .completed where job.kind == .subtitleEditing: String(localized: "\(job.segments.count) lines")
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
