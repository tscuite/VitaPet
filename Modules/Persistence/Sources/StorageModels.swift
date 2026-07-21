import Foundation

public struct StorageSchemaReadiness: Sendable, Equatable {
    public let coreReady: Bool
    public let optimized: Bool
    public let degradedReason: String?

    public init(coreReady: Bool, optimized: Bool, degradedReason: String?) {
        self.coreReady = coreReady
        self.optimized = optimized
        self.degradedReason = degradedReason
    }
}

public struct StorageFeatureGates: Sendable, Equatable {
    public var retentionEnabled: Bool
    public var fullCompactionEnabled: Bool
    public var schedulerEnabled: Bool

    public init(
        retentionEnabled: Bool,
        fullCompactionEnabled: Bool,
        schedulerEnabled: Bool
    ) {
        self.retentionEnabled = retentionEnabled
        self.fullCompactionEnabled = fullCompactionEnabled
        self.schedulerEnabled = schedulerEnabled
    }
}

public enum StorageSchema {
    public static let currentVersion = 2
}

public struct ArchivedConversationTurn: Codable, Sendable, Equatable {
    public let id: Int64
    public let role: String
    public let content: String
    public let timestamp: TimeInterval
    public let sessionID: String
    public let petID: String?
    public let petName: String?

    public init(
        id: Int64,
        role: String,
        content: String,
        timestamp: TimeInterval,
        sessionID: String,
        petID: String?,
        petName: String?
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.petID = petID
        self.petName = petName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case timestamp
        case sessionID = "session_id"
        case petID = "pet_id"
        case petName = "pet_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        petID = try container.decodeIfPresent(String.self, forKey: .petID)
        petName = try container.decodeIfPresent(String.self, forKey: .petName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(sessionID, forKey: .sessionID)
        if let petID {
            try container.encode(petID, forKey: .petID)
        } else {
            try container.encodeNil(forKey: .petID)
        }
        if let petName {
            try container.encode(petName, forKey: .petName)
        } else {
            try container.encodeNil(forKey: .petName)
        }
    }
}

public struct EncodedConversationArchive: Sendable, Equatable {
    public let archiveID: String
    public let sessionID: String
    public let firstTurnID: Int64
    public let lastTurnID: Int64
    public let membershipDigest: String
    public let turnCount: Int
    public let codec: String
    public let formatVersion: Int
    public let compressedPayload: Data
    public let uncompressedBytes: Int
    public let payloadChecksum: String

    public init(
        archiveID: String,
        sessionID: String,
        firstTurnID: Int64,
        lastTurnID: Int64,
        membershipDigest: String,
        turnCount: Int,
        codec: String,
        formatVersion: Int,
        compressedPayload: Data,
        uncompressedBytes: Int,
        payloadChecksum: String
    ) {
        self.archiveID = archiveID
        self.sessionID = sessionID
        self.firstTurnID = firstTurnID
        self.lastTurnID = lastTurnID
        self.membershipDigest = membershipDigest
        self.turnCount = turnCount
        self.codec = codec
        self.formatVersion = formatVersion
        self.compressedPayload = compressedPayload
        self.uncompressedBytes = uncompressedBytes
        self.payloadChecksum = payloadChecksum
    }
}

public struct ConversationArchiveRecord: Sendable, Equatable {
    public let archiveID: String
    public let sessionID: String
    public let firstTurnID: Int64
    public let lastTurnID: Int64
    public let membershipDigest: String
    public let turnCount: Int
    public let codec: String
    public let formatVersion: Int
    public let compressedPayload: Data
    public let uncompressedBytes: Int
    public let payloadChecksum: String
    public let createdAt: Date

    public init(
        archiveID: String,
        sessionID: String,
        firstTurnID: Int64,
        lastTurnID: Int64,
        membershipDigest: String,
        turnCount: Int,
        codec: String,
        formatVersion: Int,
        compressedPayload: Data,
        uncompressedBytes: Int,
        payloadChecksum: String,
        createdAt: Date
    ) {
        self.archiveID = archiveID
        self.sessionID = sessionID
        self.firstTurnID = firstTurnID
        self.lastTurnID = lastTurnID
        self.membershipDigest = membershipDigest
        self.turnCount = turnCount
        self.codec = codec
        self.formatVersion = formatVersion
        self.compressedPayload = compressedPayload
        self.uncompressedBytes = uncompressedBytes
        self.payloadChecksum = payloadChecksum
        self.createdAt = createdAt
    }
}

public struct ConversationArchiveResult: Sendable, Equatable {
    public let createdArchiveCount: Int
    public let archivedTurnCount: Int

    public init(createdArchiveCount: Int, archivedTurnCount: Int) {
        self.createdArchiveCount = createdArchiveCount
        self.archivedTurnCount = archivedTurnCount
    }
}

public struct EventRollupBucket: Sendable, Equatable, Codable {
    public let bucketStart: Int64
    public let source: String
    public let eventCount: Int64

    public init(bucketStart: Int64, source: String, eventCount: Int64) {
        self.bucketStart = bucketStart
        self.source = source
        self.eventCount = eventCount
    }
}

public struct FileEventRepresentative: Sendable, Equatable, Codable {
    public let timestamp: TimeInterval
    public let source: String
    public let path: String
    public let flags: UInt32

    public init(timestamp: TimeInterval, source: String = "fileChanged", path: String, flags: UInt32) {
        self.timestamp = timestamp
        self.source = source
        self.path = path
        self.flags = flags
    }
}

public struct FileEventDelivery: Sendable, Equatable {
    public let timestamp: Date
    public let path: String
    public let flags: UInt32

    public init(timestamp: Date = Date(), path: String, flags: UInt32) {
        self.timestamp = timestamp
        self.path = path
        self.flags = flags
    }
}

public struct EventRollupBatch: Sendable, Equatable, Codable {
    public let id: UUID
    public let formatVersion: Int
    public let digest: String
    public let buckets: [EventRollupBucket]
    public let representatives: [FileEventRepresentative]

    public init(id: UUID, formatVersion: Int = 1, digest: String, buckets: [EventRollupBucket], representatives: [FileEventRepresentative]) {
        self.id = id
        self.formatVersion = formatVersion
        self.digest = digest
        self.buckets = buckets
        self.representatives = representatives
    }
}

public struct EventBatchAcknowledgement: Sendable, Equatable {
    public let id: UUID
    public let digest: String

    public init(id: UUID, digest: String) {
        self.id = id
        self.digest = digest
    }
}

public struct StorageMaintenanceReport: Sendable, Equatable {
    public let archivedTurnCount: Int
    public let rolledUpEventCount: Int
    public let deletedEventCount: Int
    public let deletedRollupCount: Int
    public let reclaimedBytes: Int64

    public init(archivedTurnCount: Int, rolledUpEventCount: Int, deletedEventCount: Int, deletedRollupCount: Int, reclaimedBytes: Int64) {
        self.archivedTurnCount = archivedTurnCount
        self.rolledUpEventCount = rolledUpEventCount
        self.deletedEventCount = deletedEventCount
        self.deletedRollupCount = deletedRollupCount
        self.reclaimedBytes = reclaimedBytes
    }
}

public struct StorageMetricsSnapshot: Sendable, Equatable {
    public let liveConversationTurnCount: Int64
    public let conversationArchiveCount: Int64
    public let archivedConversationTurnCount: Int64
    public let archiveCompressedBytes: Int64
    public let archiveUncompressedBytes: Int64
    public let rawEventCount: Int64
    public let rolledUpEventCount: Int64
    public let eventRollupBatchCount: Int64
    public let databaseBytes: Int64
    public let walBytes: Int64

    public init(
        liveConversationTurnCount: Int64,
        conversationArchiveCount: Int64,
        archivedConversationTurnCount: Int64,
        archiveCompressedBytes: Int64,
        archiveUncompressedBytes: Int64,
        rawEventCount: Int64,
        rolledUpEventCount: Int64,
        eventRollupBatchCount: Int64,
        databaseBytes: Int64,
        walBytes: Int64
    ) {
        self.liveConversationTurnCount = liveConversationTurnCount
        self.conversationArchiveCount = conversationArchiveCount
        self.archivedConversationTurnCount = archivedConversationTurnCount
        self.archiveCompressedBytes = archiveCompressedBytes
        self.archiveUncompressedBytes = archiveUncompressedBytes
        self.rawEventCount = rawEventCount
        self.rolledUpEventCount = rolledUpEventCount
        self.eventRollupBatchCount = eventRollupBatchCount
        self.databaseBytes = databaseBytes
        self.walBytes = walBytes
    }
}

public struct DatabaseCloseFailure: Sendable, Equatable {
    public let resultCode: Int32
    public let message: String

    public init(resultCode: Int32, message: String) {
        self.resultCode = resultCode
        self.message = message
    }
}

public enum DatabaseCloseResult: Sendable, Equatable {
    case closed
    case alreadyClosed(previousFailure: DatabaseCloseFailure?)
    case failed(DatabaseCloseFailure)

    public var succeeded: Bool {
        switch self {
        case .closed, .alreadyClosed:
            true
        case .failed:
            false
        }
    }
}

public enum DatabaseLifecycleError: LocalizedError, Sendable, Equatable {
    case closed
    case closeFailed(DatabaseCloseFailure)

    public var errorDescription: String? {
        switch self {
        case .closed:
            "The database manager is closed and cannot be reopened."
        case let .closeFailed(failure):
            "The database manager is terminal after a failed close (SQLite \(failure.resultCode)): \(failure.message)"
        }
    }
}
