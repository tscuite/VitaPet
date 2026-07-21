import Foundation

public struct EventRollupRecoveryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.fileURL = baseURL
                .appendingPathComponent("VitaPet", isDirectory: true)
                .appendingPathComponent("pending-event-rollups.json")
        }
    }

    public func load() throws -> [EventRollupBatch] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode(
            [EventRollupBatch].self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func save(_ batches: [EventRollupBatch]) throws {
        guard !batches.isEmpty else {
            try removeIfPresent()
            return
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(batches).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func removeIfPresent() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
