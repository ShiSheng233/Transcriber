import Foundation
import JobQueue
import Observation
import TranscriberCore

/// The activity log and a one-line summary of what is happening now.
@Observable
final class ActivityViewModel {
    private static let capacity = 5_000

    private(set) var entries: [LogEntry] = []
    /// Show timings, counts and file paths, not only the main steps.
    private(set) var showsDetails = true
    private(set) var isBusy = false
    /// "2 of 5" while several files are queued.
    private(set) var queuePositionText: String?
    /// The running job's step and file, e.g. "Transcribing" and "movie.mp4".
    private(set) var stepText: String?
    private(set) var runningFileName: String?
    /// 0…1 while a step with known progress runs.
    private(set) var fractionCompleted: Double?
    /// "153/309 · about 4 min left".
    private(set) var progressDetailText: String?

    /// When the running job's current counted step began, for the estimate.
    @ObservationIgnored private var stepStart: (jobID: UUID, step: String, date: Date)?

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(queue: JobQueue) {
        tasks.append(Task { [weak self] in
            for await entry in await queue.logs() {
                self?.append(entry)
            }
        })
        tasks.append(Task { [weak self] in
            for await jobs in await queue.snapshots() {
                self?.apply(jobs)
            }
        })
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    /// The status bar's first line when idle: the outcome of the last main step.
    var idleText: String {
        entries.last { $0.level != .detail }?.message ?? String(localized: "Ready")
    }

    var latestLevel: LogEntry.Level? {
        entries.last { $0.level != .detail }?.level
    }

    var visibleEntries: [LogEntry] {
        showsDetails ? entries : entries.filter { $0.level != .detail }
    }

    func line(for entry: LogEntry) -> String {
        let marker = switch entry.level {
        case .info, .detail: " "
        case .warning: "!"
        case .error: "✕"
        }
        let indent = entry.level == .detail ? "    " : ""
        return "\(dateFormatter.string(from: entry.date)) \(marker) \(indent)\(entry.message)"
    }

    var logText: String {
        visibleEntries.map(line(for:)).joined(separator: "\n")
    }

    func setShowsDetails(_ showsDetails: Bool) {
        self.showsDetails = showsDetails
    }

    func clear() {
        entries = []
    }

    private func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    private func apply(_ jobs: [Job]) {
        let running = jobs.first { !$0.status.isFinished && $0.status != .queued }
        isBusy = running != nil
        if isBusy, jobs.count > 1 {
            let finished = jobs.filter(\.status.isFinished).count
            queuePositionText = String(localized: "\(finished + 1) of \(jobs.count)")
        } else {
            queuePositionText = nil
        }
        guard let running else {
            stepText = nil
            runningFileName = nil
            fractionCompleted = nil
            progressDetailText = nil
            stepStart = nil
            return
        }
        runningFileName = running.sourceURL.lastPathComponent
        let counted: (step: String, completed: Int, total: Int)? = switch running.status {
        case .transcribing(let completed, let total): (String(localized: "Transcribing"), completed, total)
        case .refining(let completed, let total): (String(localized: "Improving with LLM"), completed, total)
        default: nil
        }
        let uncountedStep: String = switch running.status {
        case .loadingModel: String(localized: "Loading \(running.model.displayName)")
        case .decodingAudio: String(localized: "Reading audio")
        case .detectingSpeech: String(localized: "Finding speech")
        case .exporting: String(localized: "Writing subtitles")
        default: String(localized: "Working")
        }
        stepText = counted?.step ?? uncountedStep
        fractionCompleted = running.status.fractionCompleted
        guard let counted else {
            progressDetailText = nil
            return
        }
        if stepStart?.jobID != running.id || stepStart?.step != counted.step {
            stepStart = (running.id, counted.step, Date())
        }
        var detail = "\(counted.completed)/\(counted.total)"
        if let remaining = remainingTime(completed: counted.completed, total: counted.total) {
            detail += " · " + remaining
        }
        progressDetailText = detail
    }

    /// From the pace so far; nothing until there is enough to go on.
    private func remainingTime(completed: Int, total: Int) -> String? {
        guard let stepStart, completed >= 2, completed < total else {
            return nil
        }
        let elapsed = Date().timeIntervalSince(stepStart.date)
        guard elapsed >= 3 else {
            return nil
        }
        let remaining = elapsed / Double(completed) * Double(total - completed)
        if remaining < 60 {
            return String(localized: "less than a minute left")
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        return String(localized: "about \(formatter.string(from: remaining) ?? "") left")
    }
}
