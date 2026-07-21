@testable import ChatUI
import XCTest

final class ChatMessageParserTests: XCTestCase {
    func testParseCoversAllStreamingTagStates() {
        XCTAssertEqual(
            ChatMessageParser.parse("plain reply"),
            ParsedChatMessage(thinking: nil, reply: "plain reply")
        )
        XCTAssertEqual(
            ChatMessageParser.parse("before <think> reason </think> after"),
            ParsedChatMessage(thinking: "reason", reply: "before  after")
        )
        XCTAssertEqual(
            ChatMessageParser.parse("<THINK>reason"),
            ParsedChatMessage(thinking: "reason", reply: "")
        )
        XCTAssertEqual(
            ChatMessageParser.parse("prefix</ThInK>reply"),
            ParsedChatMessage(thinking: "prefix", reply: "reply")
        )
        XCTAssertEqual(
            ChatMessageParser.parse("<think>  </think>reply"),
            ParsedChatMessage(thinking: nil, reply: "reply")
        )
    }
}
