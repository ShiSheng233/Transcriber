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

    /// For the status bar: while working, the latest entry (details too, so it
    /// keeps moving); when idle, the outcome of the last main step.
    var statusText: String {
        guard let latest = statusEntry else {
            return String(localized: "Ready")
        }
        return isBusy || latest.level != .info ? latest.message : String(localized: "Ready · \(latest.message)")
    }

    var latestLevel: LogEntry.Level? {
        statusEntry?.level
    }

    private var statusEntry: LogEntry? {
        isBusy ? entries.last : entries.last { $0.level != .detail }
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
        isBusy = jobs.contains { !$0.status.isFinished && $0.status != .queued }
        if isBusy, jobs.count > 1 {
            let finished = jobs.filter(\.status.isFinished).count
            queuePositionText = String(localized: "\(finished + 1) of \(jobs.count)")
        } else {
            queuePositionText = nil
        }
    }
}
