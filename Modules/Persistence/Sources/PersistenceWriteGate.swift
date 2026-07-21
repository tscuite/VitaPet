import Foundation

public final class PersistenceWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var unfinished: Set<UInt64> = []
    private var sealed = false
    private var waiters: [(watermark: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    public func submit<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> Task<T, Error> {
        lock.lock()
        guard !sealed else { lock.unlock(); throw PersistenceWriteGateError.closed }
        nextSequence += 1
        let sequence = nextSequence
        unfinished.insert(sequence)
        lock.unlock()
        return Task {
            defer {
                finish(sequence)
            }
            return try await operation()
        }
    }

    public func seal() -> UInt64 {
        lock.lock(); sealed = true; let watermark = nextSequence; lock.unlock(); return watermark
    }

    @discardableResult
    public func sealAndWait() async -> UInt64 {
        let watermark = seal()
        await wait(through: watermark)
        return watermark
    }

    public func wait(through watermark: UInt64) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let isComplete = !unfinished.contains { $0 <= watermark }
            if !isComplete {
                waiters.append((watermark, continuation))
            }
            lock.unlock()

            if isComplete {
                continuation.resume()
            }
        }
    }

    public func pendingCount() -> Int { lock.lock(); defer { lock.unlock() }; return unfinished.count }

    private func finish(_ sequence: UInt64) {
        lock.lock()
        unfinished.remove(sequence)
        var completedWaiters: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            let isComplete = !unfinished.contains { $0 <= waiter.watermark }
            if isComplete {
                completedWaiters.append(waiter.continuation)
            }
            return isComplete
        }
        lock.unlock()

        completedWaiters.forEach { $0.resume() }
    }
}

public enum PersistenceWriteGateError: Error, Sendable, Equatable { case closed }
