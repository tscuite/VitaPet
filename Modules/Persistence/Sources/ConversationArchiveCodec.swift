import Compression
import CryptoKit
import Foundation

public enum ConversationArchiveCodec {
    public static let codec = "lzfse"
    public static let formatVersion = 1
    public static let maximumUncompressedBytes = 64 * 1_024 * 1_024

    public static func encode(
        _ turns: [ArchivedConversationTurn]
    ) throws -> EncodedConversationArchive {
        guard let first = turns.first, let last = turns.last else {
            throw ConversationArchiveCodecError.emptyArchive
        }
        guard turns.count <= Int(Int32.max) else {
            throw ConversationArchiveCodecError.archiveTooLarge
        }

        var previousID: Int64?
        for turn in turns {
            guard turn.sessionID == first.sessionID else {
                throw ConversationArchiveCodecError.mixedSessions
            }
            guard turn.timestamp.isFinite else {
                throw ConversationArchiveCodecError.invalidTimestamp
            }
            if let previousID, turn.id <= previousID {
                throw ConversationArchiveCodecError.invalidTurnOrder
            }
            previousID = turn.id
        }

        let encoder = canonicalEncoder()
        let payload = try encoder.encode(
            ConversationArchiveEnvelope(formatVersion: formatVersion, turns: turns)
        )
        guard payload.count <= maximumUncompressedBytes else {
            throw ConversationArchiveCodecError.archiveTooLarge
        }

        let orderedIDs = turns.map(\.id)
        let membershipBytes = try encoder.encode(
            ConversationArchiveMembership(orderedTurnIDs: orderedIDs)
        )
        let payloadChecksum = sha256Hex(payload)
        let membershipDigest = sha256Hex(membershipBytes)
        let identityBytes = try encoder.encode(
            ConversationArchiveIdentity(
                domain: "com.vitapet.conversation-archive.v1",
                formatVersion: formatVersion,
                sessionID: first.sessionID,
                orderedTurnIDs: orderedIDs,
                payloadChecksum: payloadChecksum
            )
        )

        return EncodedConversationArchive(
            archiveID: sha256Hex(identityBytes),
            sessionID: first.sessionID,
            firstTurnID: first.id,
            lastTurnID: last.id,
            membershipDigest: membershipDigest,
            turnCount: turns.count,
            codec: codec,
            formatVersion: formatVersion,
            compressedPayload: try compress(payload),
            uncompressedBytes: payload.count,
            payloadChecksum: payloadChecksum
        )
    }

    public static func decode(
        _ archive: EncodedConversationArchive
    ) throws -> [ArchivedConversationTurn] {
        try decodeAndVerify(
            archiveID: archive.archiveID,
            sessionID: archive.sessionID,
            firstTurnID: archive.firstTurnID,
            lastTurnID: archive.lastTurnID,
            membershipDigest: archive.membershipDigest,
            turnCount: archive.turnCount,
            codec: archive.codec,
            formatVersion: archive.formatVersion,
            compressedPayload: archive.compressedPayload,
            uncompressedBytes: archive.uncompressedBytes,
            payloadChecksum: archive.payloadChecksum
        )
    }

    public static func decode(
        _ record: ConversationArchiveRecord
    ) throws -> [ArchivedConversationTurn] {
        try decodeAndVerify(
            archiveID: record.archiveID,
            sessionID: record.sessionID,
            firstTurnID: record.firstTurnID,
            lastTurnID: record.lastTurnID,
            membershipDigest: record.membershipDigest,
            turnCount: record.turnCount,
            codec: record.codec,
            formatVersion: record.formatVersion,
            compressedPayload: record.compressedPayload,
            uncompressedBytes: record.uncompressedBytes,
            payloadChecksum: record.payloadChecksum
        )
    }
}

private extension ConversationArchiveCodec {
    struct ConversationArchiveEnvelope: Codable {
        let formatVersion: Int
        let turns: [ArchivedConversationTurn]

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case turns
        }
    }

    struct ConversationArchiveMembership: Codable {
        let orderedTurnIDs: [Int64]

        enum CodingKeys: String, CodingKey {
            case orderedTurnIDs = "ordered_turn_ids"
        }
    }

    struct ConversationArchiveIdentity: Codable {
        let domain: String
        let formatVersion: Int
        let sessionID: String
        let orderedTurnIDs: [Int64]
        let payloadChecksum: String

        enum CodingKeys: String, CodingKey {
            case domain
            case formatVersion = "format_version"
            case sessionID = "session_id"
            case orderedTurnIDs = "ordered_turn_ids"
            case payloadChecksum = "payload_checksum"
        }
    }

    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func compress(_ input: Data) throws -> Data {
        guard !input.isEmpty else { throw ConversationArchiveCodecError.emptyArchive }
        var capacity = max(256, input.count)
        let hardLimit = maximumUncompressedBytes + (maximumUncompressedBytes / 8) + 4_096

        while capacity <= hardLimit {
            var output = Data(count: capacity)
            let encodedCount = output.withUnsafeMutableBytes { outputBuffer in
                input.withUnsafeBytes { inputBuffer in
                    compression_encode_buffer(
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        input.count,
                        nil,
                        COMPRESSION_LZFSE
                    )
                }
            }
            if encodedCount > 0 {
                output.removeSubrange(encodedCount..<output.count)
                return output
            }
            let (next, overflowed) = capacity.multipliedReportingOverflow(by: 2)
            guard !overflowed, next > capacity else {
                throw ConversationArchiveCodecError.compressionFailed
            }
            capacity = min(next, hardLimit)
            if capacity == hardLimit {
                var finalOutput = Data(count: capacity)
                let finalCount = finalOutput.withUnsafeMutableBytes { outputBuffer in
                    input.withUnsafeBytes { inputBuffer in
                        compression_encode_buffer(
                            outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                            capacity,
                            inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                            input.count,
                            nil,
                            COMPRESSION_LZFSE
                        )
                    }
                }
                guard finalCount > 0 else {
                    throw ConversationArchiveCodecError.compressionFailed
                }
                finalOutput.removeSubrange(finalCount..<finalOutput.count)
                return finalOutput
            }
        }
        throw ConversationArchiveCodecError.compressionFailed
    }

    static func decompress(_ input: Data, expectedBytes: Int) throws -> Data {
        guard expectedBytes > 0, expectedBytes <= maximumUncompressedBytes,
              !input.isEmpty else {
            throw ConversationArchiveCodecError.invalidUncompressedSize
        }
        var output = Data(count: expectedBytes)
        let decodedCount = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    expectedBytes,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    input.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decodedCount == expectedBytes else {
            throw ConversationArchiveCodecError.decompressionFailed
        }
        return output
    }

    static func decodeAndVerify(
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
    ) throws -> [ArchivedConversationTurn] {
        guard codec == self.codec else { throw ConversationArchiveCodecError.unsupportedCodec }
        guard formatVersion == self.formatVersion else {
            throw ConversationArchiveCodecError.unsupportedFormatVersion
        }
        guard turnCount > 0, firstTurnID <= lastTurnID else {
            throw ConversationArchiveCodecError.invalidMetadata
        }

        let payload = try decompress(compressedPayload, expectedBytes: uncompressedBytes)
        guard sha256Hex(payload) == payloadChecksum else {
            throw ConversationArchiveCodecError.checksumMismatch
        }
        let envelope = try JSONDecoder().decode(ConversationArchiveEnvelope.self, from: payload)
        guard envelope.formatVersion == formatVersion else {
            throw ConversationArchiveCodecError.unsupportedFormatVersion
        }
        let regenerated = try encode(envelope.turns)
        guard regenerated.archiveID == archiveID,
              regenerated.sessionID == sessionID,
              regenerated.firstTurnID == firstTurnID,
              regenerated.lastTurnID == lastTurnID,
              regenerated.membershipDigest == membershipDigest,
              regenerated.turnCount == turnCount,
              regenerated.codec == codec,
              regenerated.formatVersion == formatVersion,
              regenerated.uncompressedBytes == uncompressedBytes,
              regenerated.payloadChecksum == payloadChecksum,
              regenerated.compressedPayload == compressedPayload else {
            throw ConversationArchiveCodecError.invalidMetadata
        }
        return envelope.turns
    }
}

public enum ConversationArchiveCodecError: LocalizedError, Sendable {
    case emptyArchive
    case mixedSessions
    case invalidTimestamp
    case invalidTurnOrder
    case archiveTooLarge
    case unsupportedCodec
    case unsupportedFormatVersion
    case invalidUncompressedSize
    case compressionFailed
    case decompressionFailed
    case checksumMismatch
    case invalidMetadata

    public var errorDescription: String? {
        switch self {
        case .emptyArchive: "Conversation archive cannot be empty."
        case .mixedSessions: "Conversation archive turns must belong to one session."
        case .invalidTimestamp: "Conversation archive contains a non-finite timestamp."
        case .invalidTurnOrder: "Conversation archive turn IDs must be strictly increasing."
        case .archiveTooLarge: "Conversation archive exceeds its size limit."
        case .unsupportedCodec: "Conversation archive uses an unsupported codec."
        case .unsupportedFormatVersion: "Conversation archive uses an unsupported format version."
        case .invalidUncompressedSize: "Conversation archive has an invalid uncompressed size."
        case .compressionFailed: "Conversation archive compression failed."
        case .decompressionFailed: "Conversation archive decompression failed."
        case .checksumMismatch: "Conversation archive checksum verification failed."
        case .invalidMetadata: "Conversation archive metadata verification failed."
        }
    }
}
