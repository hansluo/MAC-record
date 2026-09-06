import Foundation

final class RealtimeAudioPump: @unchecked Sendable {
    private let continuation: AsyncStream<[Float]>.Continuation
    private let worker: Task<Void, Never>
    private let lock = NSLock()
    private var _droppedBufferCount = 0

    init(service: NativeASRService, sessionId: String, capacity: Int = 32) {
        let pair = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        continuation = pair.continuation
        worker = Task.detached(priority: .userInitiated) {
            for await samples in pair.stream {
                _ = await service.realtimeFeed(sessionId: sessionId, samples: samples)
            }
        }
    }

    func enqueue(_ samples: [Float]) {
        if case .dropped = continuation.yield(samples) {
            lock.lock()
            _droppedBufferCount += 1
            lock.unlock()
        }
    }

    var droppedBufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _droppedBufferCount
    }

    func finish() async {
        continuation.finish()
        await worker.value
    }
}
