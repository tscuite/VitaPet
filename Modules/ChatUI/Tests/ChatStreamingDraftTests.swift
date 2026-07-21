@testable import ChatUI
import XCTest

final class ChatStreamingDraftTests: XCTestCase {
    func testPresentationOnlyProjectsMatchingConversationAndMessage() {
        let settled = ChatMessage(role: .assistant, content: "")
        let unrelated = ChatMessage(role: .assistant, content: "settled")
        var draft = ChatStreamingDraft(conversationId: "origin", message: settled)

        draft.update(content: "partial")

        XCTAssertEqual(draft.presentedMessage(replacing: settled, in: "origin").content, "partial")
        XCTAssertEqual(draft.presentedMessage(replacing: settled, in: "other"), settled)
        XCTAssertEqual(draft.presentedMessage(replacing: unrelated, in: "origin"), unrelated)
    }
}
