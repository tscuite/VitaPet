import Foundation

public actor StorageMaintenanceCoordinator {
    public typealias Operation = @Sendable () async throws -> StorageMaintenanceReport

    private let operation: Operation
    private var activeRun: (id: UUID, task: Task<StorageMaintenanceReport, Error>)?

    public init(operation: @escaping Operation) {
        self.operation = operation
    }

    public func run() async throws -> StorageMaintenanceReport {
        if let activeRun {
            return try await activeRun.task.value
        }

        let id = UUID()
        let task = Task { [operation] in
            try await operation()
        }
        activeRun = (id, task)

        do {
            let report = try await task.value
            clearActiveRun(ifMatching: id)
            return report
        } catch {
            clearActiveRun(ifMatching: id)
            throw error
        }
    }

    public func cancelAndWait() async {
        guard let activeRun else { return }
        activeRun.task.cancel()
        _ = await activeRun.task.result
        clearActiveRun(ifMatching: activeRun.id)
    }

    public func isRunning() -> Bool {
        activeRun != nil
    }

    private func clearActiveRun(ifMatching id: UUID) {
        guard activeRun?.id == id else { return }
        activeRun = nil
    }
}
