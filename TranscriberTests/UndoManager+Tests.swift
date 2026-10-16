import Foundation

extension UndoManager {
    /// Long enough for the run loop to reach the point where it would wait.
    private static let eventEnd: TimeInterval = 0.01

    /// Runs `body` as one user event: the undo manager groups what it
    /// registers by event, as the window's does, and closes the group when
    /// the run loop goes idle. An event that registers nothing (typing that
    /// joins the current step) adds no step.
    func step(_ body: () -> Void) {
        body()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.eventEnd))
    }
}
