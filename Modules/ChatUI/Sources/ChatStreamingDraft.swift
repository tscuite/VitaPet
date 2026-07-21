import Foundation

/// The observable, in-flight projection of one settled assistant placeholder.
/// Updating this value never copies a conversation's settled message array.
struct ChatStreamingDraft: Equatable, Sendable {
    let conversationId: String
    private(set) var message: ChatMessage

    init(conversationId: String, message: ChatMessage) {
        self.conversationId = conversationId
        self.message = message
    }

    var content: String { message.content }

    mutating func update(content: String) {
        guard content != message.content else { return }
        message = ChatMessage(
            id: message.id,
            role: message.role,
            content: content,
            timestamp: message.timestamp,
            petId: message.petId,
            petName: message.petName
        )
    }

    func presentedMessage(replacing settledMessage: ChatMessage, in conversationId: String) -> ChatMessage {
        guard self.conversationId == conversationId,
              message.id == settledMessage.id else {
            return settledMessage
        }
        return message
    }
}
