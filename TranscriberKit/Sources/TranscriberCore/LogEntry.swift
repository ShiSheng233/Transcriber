import Foundation

/// One line of the activity log: what the queue and pipeline are doing.
public struct LogEntry: Hashable, Sendable, Identifiable {
    public enum Level: Hashable, Sendable {
        case info
        /// Details only shown in the full log (timings, counts).
        case detail
        case warning
        case error
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    /// The job it belongs to, if any.
    public let jobID: UUID?
    public let message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: Level, jobID: UUID?, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.jobID = jobID
        self.message = message
    }
}
