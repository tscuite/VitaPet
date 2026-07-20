import Foundation

public final class PersistenceWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var unfinished: Set<UInt64> = []
    private var sealed = false

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

    public func pendingCount() -> Int { lock.lock(); defer { lock.unlock() }; return unfinished.count }

    private func finish(_ sequence: UInt64) {
        lock.lock()
        unfinished.remove(sequence)
        lock.unlock()
    }
}

public enum PersistenceWriteGateError: Error, Sendable { case closed }
