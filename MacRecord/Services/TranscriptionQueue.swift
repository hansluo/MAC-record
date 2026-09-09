import Foundation

actor TranscriptionQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isRunning = false
    private var waiters: [Waiter] = []
    private var cancelledWaiterIds: Set<UUID> = []

    func enqueue<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let waiterId = UUID()
        try await acquire(waiterId: waiterId)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(waiterId: UUID) async throws {
        try Task.checkCancellation()
        if !isRunning {
            isRunning = true
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || cancelledWaiterIds.remove(waiterId) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterId, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterId) }
        }
    }

    private func cancelWaiter(_ waiterId: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == waiterId }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelledWaiterIds.insert(waiterId)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isRunning = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }
}
