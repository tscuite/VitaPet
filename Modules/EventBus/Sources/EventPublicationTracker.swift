import Foundation

/// Bridges synchronous system callbacks into EventBus while retaining a drain point for shutdown.
public final class EventPublicationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var pendingCount = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    @discardableResult
    public func publish(_ event: AppEvent, to eventBus: EventBus) -> Bool {
        submit {
            await eventBus.publish(event)
        }
    }

    @discardableResult
    public func submit(_ operation: @escaping @Sendable () async -> Void) -> Bool {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return false
        }
        pendingCount += 1
        lock.unlock()

        Task { [self] in
            await operation()
            finishPublication()
        }
        return true
    }

    public func stopAccepting() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    public func drain() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let isDrained = pendingCount == 0
            if !isDrained {
                drainWaiters.append(continuation)
            }
            lock.unlock()

            if isDrained {
                continuation.resume()
            }
        }
    }

    public func stopAndDrain() async {
        stopAccepting()
        await drain()
    }

    private func finishPublication() {
        lock.lock()
        pendingCount -= 1
        let waiters = pendingCount == 0 ? drainWaiters : []
        if pendingCount == 0 {
            drainWaiters.removeAll()
        }
        lock.unlock()

        waiters.forEach { $0.resume() }
    }
}
