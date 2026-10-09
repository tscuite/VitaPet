import Foundation
import RenderEngine

/// Care data is separate from configuration and chat storage; no database migration is needed.
@MainActor
public final class CompanionStore {
    private struct SaveFile: Codable {
        var version = 1
        var pets: [String: CompanionProgress] = [:]
    }

    public enum StoreError: Error {
        case invalidSave
    }

    private let fileURL: URL
    private var loaded: SaveFile?

    public init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VitaPet", isDirectory: true)
        fileURL = root.appendingPathComponent("companion.json")
    }

    public func progress(for petID: UUID, at now: Date = Date()) throws -> CompanionProgress {
        var save = try load()
        if let progress = save.pets[petID.uuidString] { return progress }
        let progress = CompanionProgress(now: now)
        save.pets[petID.uuidString] = progress
        loaded = save
        return progress
    }

    @discardableResult
    public func perform(_ action: CareAction, for petID: UUID, at now: Date = Date()) throws -> Int {
        var candidate = try load()
        var progress = candidate.pets[petID.uuidString] ?? CompanionProgress(now: now)
        let earned = try progress.perform(action, at: now)
        candidate.pets[petID.uuidString] = progress
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(to: fileURL, options: .atomic)
        // A failed write must not award progress or consume a cooldown in memory.
        loaded = candidate
        return earned
    }

    private func load() throws -> SaveFile {
        if let loaded { return loaded }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            let empty = SaveFile()
            loaded = empty
            return empty
        }
        let save = try JSONDecoder().decode(SaveFile.self, from: data)
        guard save.version == 1, save.pets.values.allSatisfy(\.isValid) else {
            throw StoreError.invalidSave
        }
        loaded = save
        return save
    }
}
