public actor RemoteMemoryBootstrapCoordinator {
    private enum State {
        case waitingForVisibleUI
        case ready
        case started
        case stopped
    }

    private var state: State = .waitingForVisibleUI
    private var task: Task<Void, Never>?

    public init() {}

    public func markVisibleUIReady() {
        guard case .waitingForVisibleUI = state else { return }
        state = .ready
    }

    @discardableResult
    public func startIfReady(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Bool {
        guard case .ready = state else { return false }
        state = .started
        task = Task { @MainActor in
            await operation()
        }
        return true
    }

    public func cancelAndWait() async {
        state = .stopped
        let task = task
        task?.cancel()
        await task?.value
        self.task = nil
    }
}
