import Foundation
import Localization
import Observation

@MainActor
@Observable
public final class ChatViewModel {
    private let defaultConversationId = "default_conversation"

    public private(set) var conversations: [ConversationThread] = []
    public var selectedConversationId: String? {
        didSet {
            if let id = selectedConversationId {
                currentMessages = messagesByConversation[id] ?? []
                onConversationChanged?(id)
            } else {
                currentMessages = []
            }
        }
    }
    public private(set) var currentMessages: [ChatMessage] = []
    public var messages: [ChatMessage] { currentMessages }
    public var inputText: String = ""
    public private(set) var aiStatus: AIEngineStatus = .notConfigured
    public private(set) var isStreaming = false
    private var messagesByConversation: [String: [ChatMessage]] = [:]
    @ObservationIgnored private var activeSendTask: Task<Void, Never>?
    @ObservationIgnored private var activeSendConversationId: String?
    // Per-message capture of the "show thinking" toggle at the moment the
    // message first lands in the view model. The toggle in ChatView only
    // affects messages appended *after* it changes — historical messages keep
    // whatever value was current when they were captured.
    @ObservationIgnored private var capturedShowThinking: [UUID: Bool] = [:]

    private let sendToAI: @Sendable (String, String, [ChatMessage]) async throws -> AsyncThrowingStream<String, Error>
    private let getAIStatus: @Sendable () async -> AIEngineStatus

    public var onUserSent: (@MainActor (_ conversationId: String, _ message: ChatMessage) -> Void)?
    public var onAssistantReplied: (@MainActor (_ conversationId: String, _ message: ChatMessage) -> Void)?
    public var onConversationChanged: ((String) -> Void)?
    public var onCreateGroup: ((String, [UUID]) -> Void)?
    public var onDeleteConversation: (@MainActor (String) -> Void)?
    /// Called when the user enters a `/command arguments` style message in the chat input.
    /// Return true to consume the message (it won't be forwarded to the AI).
    public var onSlashCommand: (@MainActor (_ name: String, _ arguments: String) async -> Bool)?

    public init(
        sendToAI: @escaping @Sendable (String, String, [ChatMessage]) async throws -> AsyncThrowingStream<String, Error> = { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        },
        getAIStatus: @escaping @Sendable () async -> AIEngineStatus = { .notConfigured }
    ) {
        self.sendToAI = sendToAI
        self.getAIStatus = getAIStatus
        // Check AI status immediately on creation
        Task { @MainActor in
            self.aiStatus = await getAIStatus()
        }
    }

    public func sendMessage() {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty, !isStreaming else {
            return
        }
        ensureSelectedConversation()
        guard let conversationId = selectedConversationId else {
            return
        }
        inputText = ""

        if let command = Self.parseSlashCommand(from: trimmedInput), let handler = onSlashCommand {
            appendToCurrentConversation(ChatMessage(role: .user, content: trimmedInput))
            Task { @MainActor in
                _ = await handler(command.name, command.arguments)
            }
            return
        }

        let userMessage = ChatMessage(role: .user, content: trimmedInput)
        append(userMessage, to: conversationId)
        let aiHistory = messagesByConversation[conversationId] ?? []
        onUserSent?(conversationId, userMessage)

        isStreaming = true
        activeSendConversationId = conversationId
        activeSendTask = Task { @MainActor in
            defer {
                isStreaming = false
                activeSendConversationId = nil
                activeSendTask = nil
            }

            guard !Task.isCancelled else {
                return
            }
            aiStatus = await getAIStatus()
            guard !Task.isCancelled else {
                return
            }

            guard aiStatus == .ready else {
                append(
                    ChatMessage(role: .assistant, content: L10n.chatAssistantNotConfigured),
                    to: conversationId
                )
                return
            }

            let assistantMessage = ChatMessage(role: .assistant, content: "")
            append(assistantMessage, to: conversationId)

            do {
                try Task.checkCancellation()
                let stream = try await sendToAI(conversationId, trimmedInput, aiHistory)
                var bufferedReply = ""

                func assistantMessageWithContent(_ content: String) -> ChatMessage {
                    ChatMessage(
                        id: assistantMessage.id,
                        role: .assistant,
                        content: content,
                        timestamp: assistantMessage.timestamp,
                        petId: assistantMessage.petId,
                        petName: assistantMessage.petName
                    )
                }

                // Consume the token-heavy upstream stream away from MainActor.
                // Only the newest accumulated snapshot crosses back to the UI,
                // so a busy render pass naturally drops stale intermediate text.
                for try await snapshot in StreamingTextBatcher.snapshots(from: stream) {
                    bufferedReply = snapshot
                    replaceMessage(
                        id: assistantMessage.id,
                        in: conversationId,
                        with: assistantMessageWithContent(bufferedReply),
                        updatesPreview: false
                    )
                }
                try Task.checkCancellation()

                let completedMessage = assistantMessageWithContent(bufferedReply)
                let didStoreReply = replaceMessage(
                    id: assistantMessage.id,
                    in: conversationId,
                    with: completedMessage,
                    updatesPreview: true
                )

                if didStoreReply {
                    onAssistantReplied?(conversationId, completedMessage)
                }
            } catch is CancellationError where Task.isCancelled {
                finalizeCancelledMessage(id: assistantMessage.id, in: conversationId)
            } catch {
                replaceMessage(
                    id: assistantMessage.id,
                    in: conversationId,
                    with: ChatMessage(
                        id: assistantMessage.id,
                        role: .assistant,
                        content: "Error: \(error.localizedDescription)",
                        timestamp: assistantMessage.timestamp,
                        petId: assistantMessage.petId,
                        petName: assistantMessage.petName
                    )
                )
            }
        }
    }

    public func cancelStreaming() {
        activeSendTask?.cancel()
    }

    public func addExternalMessage(_ content: String) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return
        }

        ensureSelectedConversation()
        appendToCurrentConversation(ChatMessage(role: .user, content: trimmedContent))
    }

    public func addAssistantMessage(
        _ content: String,
        petId: UUID? = nil,
        petName: String? = nil,
        displayThinking: Bool = true
    ) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return
        }

        ensureSelectedConversation()
        let message = ChatMessage(role: .assistant, content: trimmedContent, petId: petId, petName: petName)
        if !displayThinking {
            capturedShowThinking[message.id] = false
        }
        appendToCurrentConversation(message)
    }

    public func loadConversations(_ threads: [ConversationThread]) {
        conversations = threads
        for thread in threads where messagesByConversation[thread.id] == nil {
            messagesByConversation[thread.id] = []
        }
        if selectedConversationId == nil, let first = threads.first {
            selectedConversationId = first.id
        } else if let selectedConversationId, !threads.contains(where: { $0.id == selectedConversationId }) {
            self.selectedConversationId = threads.first?.id
        }
    }

    public func loadMessages(for conversationId: String, messages: [ChatMessage]) {
        for message in messages {
            captureShowThinkingIfNeeded(for: message.id)
        }
        messagesByConversation[conversationId] = messages
        if conversationId == selectedConversationId {
            currentMessages = messages
        }
    }

    public func selectConversation(_ id: String) {
        ensureConversationExists(id)
        selectedConversationId = id
    }

    @discardableResult
    public func createGroupChat(title: String, participantIds: [UUID]) -> ConversationThread {
        let thread = ConversationThread(
            id: "group_\(UUID().uuidString)",
            type: .group,
            participantIds: participantIds,
            title: title
        )
        conversations.append(thread)
        messagesByConversation[thread.id] = []
        selectedConversationId = thread.id
        onCreateGroup?(title, participantIds)
        return thread
    }

    public func deleteConversation(_ id: String) {
        if activeSendConversationId == id {
            cancelStreaming()
        }
        conversations.removeAll { $0.id == id }
        messagesByConversation[id] = nil
        onDeleteConversation?(id)

        if selectedConversationId == id {
            selectedConversationId = conversations.first?.id
        } else if let selectedConversationId,
                  !conversations.contains(where: { $0.id == selectedConversationId }) {
            self.selectedConversationId = conversations.first?.id
        }
    }

    public func addConversation(_ thread: ConversationThread) {
        if !conversations.contains(where: { $0.id == thread.id }) {
            conversations.append(thread)
        }
        if messagesByConversation[thread.id] == nil {
            messagesByConversation[thread.id] = []
        }
    }

    public func updateConversationTitle(_ id: String, title: String) {
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            var updated = conversations[index]
            updated = ConversationThread(
                id: updated.id,
                type: updated.type,
                participantIds: updated.participantIds,
                title: title,
                lastMessage: updated.lastMessage,
                lastTimestamp: updated.lastTimestamp,
                unreadCount: updated.unreadCount
            )
            conversations[index] = updated
        }
    }

    public func updateConversation(_ thread: ConversationThread) {
        if let index = conversations.firstIndex(where: { $0.id == thread.id }) {
            conversations[index] = thread
        } else {
            conversations.append(thread)
        }
        if messagesByConversation[thread.id] == nil {
            messagesByConversation[thread.id] = []
        }
        if selectedConversationId == thread.id {
            currentMessages = messagesByConversation[thread.id] ?? []
        }
    }

    public var currentParticipantIds: [UUID] {
        conversations.first(where: { $0.id == selectedConversationId })?.participantIds ?? []
    }

    public var currentConversationType: ConversationType? {
        conversations.first(where: { $0.id == selectedConversationId })?.type
    }

    public func refreshStatus() {
        Task { @MainActor in
            aiStatus = await getAIStatus()
        }
    }

    private func appendToCurrentConversation(_ message: ChatMessage) {
        guard let id = selectedConversationId else {
            return
        }
        append(message, to: id)
    }

    private func append(_ message: ChatMessage, to conversationId: String) {
        guard var messages = messagesByConversation[conversationId] else {
            return
        }
        captureShowThinkingIfNeeded(for: message.id)
        messages.append(message)
        messagesByConversation[conversationId] = messages
        if selectedConversationId == conversationId {
            currentMessages = messages
        }
        updateConversationPreview(for: conversationId, using: message)
    }

    /// 用清理后的内容替换最后一条助手消息（用于剥离 [ACTION:...] 标签）。
    public func replaceLastAssistantContent(_ content: String) {
        guard let id = selectedConversationId,
              let last = currentMessages.last,
              last.role == .assistant else {
            return
        }
        let updated = ChatMessage(
            id: last.id,
            role: .assistant,
            content: content,
            timestamp: last.timestamp,
            petId: last.petId,
            petName: last.petName
        )
        replaceMessage(id: last.id, in: id, with: updated)
    }

    public func replaceAssistantContent(
        _ content: String,
        messageId: UUID,
        conversationId: String
    ) {
        guard let original = messagesByConversation[conversationId]?.first(where: { $0.id == messageId }),
              original.role == .assistant else {
            return
        }
        replaceMessage(
            id: messageId,
            in: conversationId,
            with: ChatMessage(
                id: original.id,
                role: original.role,
                content: content,
                timestamp: original.timestamp,
                petId: original.petId,
                petName: original.petName
            )
        )
    }

    /// Returns the captured "show thinking" value for a given message. Falls
    /// back to the current global toggle if a capture is missing (which only
    /// happens for messages that pre-date this mechanism).
    public func showsThinking(for messageId: UUID) -> Bool {
        if let captured = capturedShowThinking[messageId] {
            return captured
        }
        return currentGlobalShowThinking()
    }

    private func captureShowThinkingIfNeeded(for messageId: UUID) {
        guard capturedShowThinking[messageId] == nil else { return }
        capturedShowThinking[messageId] = currentGlobalShowThinking()
    }

    private func currentGlobalShowThinking() -> Bool {
        // Mirror @AppStorage("chat.showThinking") default = true
        UserDefaults.standard.object(forKey: "chat.showThinking") as? Bool ?? true
    }

    @discardableResult
    private func replaceMessage(
        id messageId: UUID,
        in conversationId: String,
        with message: ChatMessage,
        updatesPreview: Bool = true
    ) -> Bool {
        guard var messages = messagesByConversation[conversationId],
              let messageIndex = messages.firstIndex(where: { $0.id == messageId }) else {
            return false
        }
        if messages[messageIndex] == message {
            if updatesPreview {
                updateConversationPreview(for: conversationId, using: message)
            }
            return true
        }
        messages[messageIndex] = message
        messagesByConversation[conversationId] = messages
        if selectedConversationId == conversationId {
            currentMessages = messages
        }
        if updatesPreview {
            updateConversationPreview(for: conversationId, using: message)
        }
        return true
    }

    private func updateConversationPreview(for conversationId: String, using message: ChatMessage) {
        // Skip the empty placeholder assistant bubble — otherwise every send
        // wipes the visible last-message preview in the sidebar and forces
        // ConversationListView (and the parent split view) to re-render twice
        // for nothing.
        guard !message.content.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }
        let newPreview = String(message.content.prefix(50))
        // Avoid spurious @Observable notifications when nothing actually changed.
        if conversations[index].lastMessage == newPreview,
           conversations[index].lastTimestamp == message.timestamp {
            return
        }
        conversations[index].lastMessage = newPreview
        conversations[index].lastTimestamp = message.timestamp
    }

    private func finalizeCancelledMessage(id messageId: UUID, in conversationId: String) {
        guard var messages = messagesByConversation[conversationId],
              let messageIndex = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        let message = messages[messageIndex]
        if message.content.isEmpty {
            messages.remove(at: messageIndex)
            messagesByConversation[conversationId] = messages
            capturedShowThinking[messageId] = nil
            if selectedConversationId == conversationId {
                currentMessages = messages
            }
        } else {
            updateConversationPreview(for: conversationId, using: message)
        }
    }

    private func ensureSelectedConversation() {
        if let selectedConversationId {
            ensureConversationExists(selectedConversationId)
            return
        }
        if let firstConversationId = conversations.first?.id {
            selectedConversationId = firstConversationId
            return
        }

        let thread = ConversationThread(
            id: defaultConversationId,
            type: .single,
            participantIds: [],
            title: ""
        )
        conversations.append(thread)
        messagesByConversation[thread.id] = []
        selectedConversationId = thread.id
    }

    private func ensureConversationExists(_ id: String) {
        if !conversations.contains(where: { $0.id == id }) {
            conversations.append(
                ConversationThread(
                    id: id,
                    type: .single,
                    participantIds: [],
                    title: ""
                )
            )
        }
        if messagesByConversation[id] == nil {
            messagesByConversation[id] = []
        }
    }

    struct SlashCommand {
        let name: String
        let arguments: String
    }

    static func parseSlashCommand(from text: String) -> SlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let body = String(trimmed.dropFirst())
        guard !body.isEmpty else { return nil }

        if let spaceIndex = body.firstIndex(where: { $0.isWhitespace }) {
            let name = String(body[..<spaceIndex])
            let arguments = String(body[body.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return SlashCommand(name: name, arguments: arguments)
        }

        return SlashCommand(name: body, arguments: "")
    }
}
