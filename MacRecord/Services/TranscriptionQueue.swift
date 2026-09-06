import Foundation

actor TranscriptionQueue {
    private var tail: Task<Void, Never>?

    func enqueue<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let predecessor = tail
        let task = Task<T, Error> {
            try Task.checkCancellation()
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
