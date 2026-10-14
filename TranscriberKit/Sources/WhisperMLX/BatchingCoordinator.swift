import Foundation

/// Groups single-token decode requests from concurrent sessions into batched
/// steps (dynamic batching).
///
/// A caller waits until every active session has a request pending, or until
/// `gatherTimeout` passes; then one waiting caller runs the step for all
/// pending requests and wakes the others. All MLX work goes through `run`,
/// one piece at a time.
final class BatchingCoordinator: @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `condition`.
    private let condition = NSCondition()
    private let gatherTimeout: TimeInterval
    private var activeSessionCount = 0
    private var pending: [(request: DecoderSlotBatch.StepRequest, ticket: Int)] = []
    private var results: [Int: [Float]] = [:]
    private var nextTicket = 0
    private var isStepRunning = false
    private let batch: DecoderSlotBatch
    private let mlxLock = NSLock()

    init(batch: DecoderSlotBatch, gatherTimeout: TimeInterval = 0.002) {
        self.batch = batch
        self.gatherTimeout = gatherTimeout
    }

    func sessionStarted() {
        condition.withLock { activeSessionCount += 1 }
    }

    func sessionEnded() {
        condition.withLock {
            activeSessionCount -= 1
            condition.broadcast()  // waiting callers may now be everyone
        }
    }

    /// Runs other MLX work (encoding) without overlapping a step.
    func run<T>(_ work: () throws -> T) rethrows -> T {
        mlxLock.lock()
        defer { mlxLock.unlock() }
        return try work()
    }

    func logits(for request: DecoderSlotBatch.StepRequest) -> [Float] {
        condition.lock()
        let ticket = nextTicket
        nextTicket += 1
        pending.append((request, ticket))
        condition.broadcast()

        let deadline = Date().addingTimeInterval(gatherTimeout)
        while true {
            if let logits = results.removeValue(forKey: ticket) {
                condition.unlock()
                return logits
            }
            let everyoneWaiting = pending.count >= activeSessionCount
            if !isStepRunning && (everyoneWaiting || Date() >= deadline) {
                runStep()
            } else {
                condition.wait(until: isStepRunning ? .distantFuture : deadline)
            }
        }
    }

    /// Called with `condition` locked; unlocks it while the GPU works.
    private func runStep() {
        let stepRequests = pending
        pending.removeAll()
        isStepRunning = true
        condition.unlock()

        let stepLogits = run { batch.step(stepRequests.map(\.request)) }

        condition.lock()
        for (entry, logits) in zip(stepRequests, stepLogits) {
            results[entry.ticket] = logits
        }
        isStepRunning = false
        condition.broadcast()
    }
}
