import Foundation
import Persistence
import XCTest

final class ConversationArchiveTests: XCTestCase {
    func testArchiveRoundTripPreservesUnicodeAndMetadata() throws {
        let turns = [
            ArchivedConversationTurn(
                id: 7,
                role: "assistant",
                content: "你好 🐾",
                timestamp: 42,
                sessionID: "session",
                petID: "pet",
                petName: "团子"
            ),
        ]

        let encoded = try ConversationArchiveCodec.encode(turns)

        XCTAssertEqual(try ConversationArchiveCodec.decode(encoded), turns)
    }
}
