import ChatUI
import XCTest

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testLoadConversations_selectsFirstByDefault() {
        let viewModel = ChatViewModel()
        let first = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "First")
        let second = ConversationThread(id: "c2", type: .group, participantIds: [UUID(), UUID()], title: "Second")

        viewModel.loadConversations([first, second])

        XCTAssertEqual(viewModel.conversations.map(\.id), ["c1", "c2"])
        XCTAssertEqual(viewModel.selectedConversationId, "c1")
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSelectConversation_switchesCurrentMessages() {
        let viewModel = ChatViewModel()
        let first = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "First")
        let second = ConversationThread(id: "c2", type: .single, participantIds: [UUID()], title: "Second")
        let firstMessage = ChatMessage(role: .user, content: "First message")
        let secondMessage = ChatMessage(role: .assistant, content: "Second message")

        viewModel.loadConversations([first, second])
        viewModel.loadMessages(for: "c1", messages: [firstMessage])
        viewModel.loadMessages(for: "c2", messages: [secondMessage])

        XCTAssertEqual(viewModel.messages.map(\.content), ["First message"])

        viewModel.selectConversation("c2")

        XCTAssertEqual(viewModel.selectedConversationId, "c2")
        XCTAssertEqual(viewModel.messages.map(\.content), ["Second message"])
    }

    func testCreateGroupChat_addsConversationAndInvokesCallback() {
        let viewModel = ChatViewModel()
        let participantIds = [UUID(), UUID()]
        var createdTitle: String?
        var createdParticipants: [UUID]?
        viewModel.onCreateGroup = { title, ids in
            createdTitle = title
            createdParticipants = ids
        }

        let thread = viewModel.createGroupChat(title: "Group", participantIds: participantIds)

        XCTAssertEqual(thread.type, .group)
        XCTAssertEqual(thread.title, "Group")
        XCTAssertEqual(thread.participantIds, participantIds)
        XCTAssertTrue(thread.id.hasPrefix("group_"))
        XCTAssertTrue(viewModel.conversations.contains(where: { $0.id == thread.id }))
        XCTAssertEqual(createdTitle, "Group")
        XCTAssertEqual(createdParticipants, participantIds)
        XCTAssertEqual(viewModel.selectedConversationId, thread.id)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testDeleteConversation_updatesSelectedConversationAndMessages() {
        let viewModel = ChatViewModel()
        let first = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "First")
        let second = ConversationThread(id: "c2", type: .group, participantIds: [UUID(), UUID()], title: "Second")
        viewModel.loadConversations([first, second])
        viewModel.loadMessages(for: "c1", messages: [ChatMessage(role: .user, content: "one")])
        viewModel.loadMessages(for: "c2", messages: [ChatMessage(role: .assistant, content: "two")])
        viewModel.selectConversation("c2")

        viewModel.deleteConversation("c2")

        XCTAssertEqual(viewModel.conversations.map(\.id), ["c1"])
        XCTAssertEqual(viewModel.selectedConversationId, "c1")
        XCTAssertEqual(viewModel.messages.map(\.content), ["one"])
    }

    func testMessages_emptyByDefault() {
        let viewModel = ChatViewModel()

        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testAiStatus_defaultIsNotConfigured() {
        let viewModel = ChatViewModel()

        XCTAssertEqual(String(describing: viewModel.aiStatus), String(describing: "notConfigured"))
    }

    func testSendMessage_addsUserMessage() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 1)

        XCTAssertEqual(viewModel.messages.first?.role, .user)
        XCTAssertEqual(viewModel.messages.first?.content, "Hello")
    }

    func testSendMessage_clearsInputText() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 1)

        XCTAssertEqual(viewModel.inputText, "")
    }

    func testSendMessage_emptyInput_doesNotSend() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "   \n"

        viewModel.sendMessage()

        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSendMessage_addsAssistantReply_whenNotConfigured() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 2)

        XCTAssertEqual(viewModel.messages.last?.role, .assistant)
        XCTAssertEqual(viewModel.messages.last?.content, "AI 尚未配置")
    }

    func testSendMessage_messageCountIncreasesBy2() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 2)

        XCTAssertEqual(viewModel.messages.count, 2)
    }

    func testSendMessage_preservesOrder() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 2)

        XCTAssertEqual(viewModel.messages.map(\.role), [.user, .assistant])
    }

    func testSendMessage_multipleMessages_accumulate() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "First"
        viewModel.sendMessage()
        wait(for: viewModel, count: 2)
        viewModel.inputText = "Second"
        viewModel.sendMessage()
        wait(for: viewModel, count: 4)

        XCTAssertEqual(viewModel.messages.count, 4)
        XCTAssertEqual(viewModel.messages[0].content, "First")
        XCTAssertEqual(viewModel.messages[2].content, "Second")
    }

    func testSendMessage_streamsAssistantReply() {
        let expectation = XCTestExpectation(description: "assistant replied")
        let viewModel = ChatViewModel(
            sendToAI: { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield("Hello")
                    continuation.yield(", ")
                    continuation.yield("World")
                    continuation.finish()
                }
            },
            getAIStatus: { .ready }
        )
        viewModel.onAssistantReplied = { _, _ in
            expectation.fulfill()
        }

        viewModel.inputText = "Hi"
        viewModel.sendMessage()
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(viewModel.messages.last?.role, .assistant)
        XCTAssertEqual(viewModel.messages.last?.content, "Hello, World")
    }

    func testSendMessage_storesMessagesInSelectedConversation() {
        let expectation = XCTestExpectation(description: "assistant replied")
        let viewModel = ChatViewModel(
            sendToAI: { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield("reply")
                    continuation.finish()
                }
            },
            getAIStatus: { .ready }
        )
        let thread = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "Chat 1")
        viewModel.loadConversations([thread])
        viewModel.onAssistantReplied = { _, _ in
            expectation.fulfill()
        }

        viewModel.inputText = "hello"
        viewModel.sendMessage()
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(viewModel.selectedConversationId, "c1")
        XCTAssertEqual(viewModel.messages.map(\.content), ["hello", "reply"])
        XCTAssertEqual(viewModel.conversations.first?.lastMessage, "reply")
    }

    func testSendMessage_streamingChunks_updatesConversationPreviewWithFinalReply() {
        let expectation = XCTestExpectation(description: "assistant replied")
        let viewModel = ChatViewModel(
            sendToAI: { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield("Hello")
                    continuation.yield(", ")
                    continuation.yield("VitaPet")
                    continuation.finish()
                }
            },
            getAIStatus: { .ready }
        )
        let thread = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "Chat 1")
        viewModel.loadConversations([thread])
        viewModel.onAssistantReplied = { _, _ in
            expectation.fulfill()
        }

        viewModel.inputText = "hi"
        viewModel.sendMessage()
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(viewModel.messages.last?.content, "Hello, VitaPet")
        XCTAssertEqual(viewModel.conversations.first?.lastMessage, "Hello, VitaPet")
    }

    func testSwitchingConversation_updatesCurrentMessagesAfterSending() {
        let replyExpectation = XCTestExpectation(description: "assistant replied")
        let viewModel = ChatViewModel(
            sendToAI: { _, input, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield("reply to \(input)")
                    continuation.finish()
                }
            },
            getAIStatus: { .ready }
        )
        let first = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "First")
        let second = ConversationThread(id: "c2", type: .single, participantIds: [UUID()], title: "Second")
        viewModel.loadConversations([first, second])
        viewModel.loadMessages(for: "c2", messages: [ChatMessage(role: .assistant, content: "existing")])
        viewModel.onAssistantReplied = { _, _ in
            replyExpectation.fulfill()
        }

        viewModel.inputText = "hello"
        viewModel.sendMessage()
        wait(for: [replyExpectation], timeout: 1.0)
        XCTAssertEqual(viewModel.messages.map(\.content), ["hello", "reply to hello"])

        viewModel.selectConversation("c2")

        XCTAssertEqual(viewModel.messages.map(\.content), ["existing"])
    }

    func testSwitchingConversationWhileStreaming_keepsReplyInOriginConversation() async {
        let replyStream = ControlledReplyStream()
        let replyExpectation = XCTestExpectation(description: "assistant replied")
        let viewModel = ChatViewModel(
            sendToAI: { conversationId, _, _ in
                replyStream.record(conversationId: conversationId)
                return replyStream.stream
            },
            getAIStatus: { .ready }
        )
        let first = ConversationThread(id: "c1", type: .single, participantIds: [], title: "First")
        let second = ConversationThread(id: "c2", type: .single, participantIds: [], title: "Second")
        viewModel.loadConversations([first, second])
        viewModel.loadMessages(
            for: "c2",
            messages: [ChatMessage(role: .assistant, content: "existing")]
        )
        viewModel.onAssistantReplied = { _, _ in
            replyExpectation.fulfill()
        }

        viewModel.inputText = "hello"
        viewModel.sendMessage()
        await waitUntil {
            viewModel.isStreaming && viewModel.messages.count == 2 && replyStream.isReady
        }

        viewModel.selectConversation("c2")
        replyStream.yield("reply")
        replyStream.finish()
        await fulfillment(of: [replyExpectation], timeout: 1.0)

        XCTAssertEqual(replyStream.requestedConversationId, "c1")
        XCTAssertEqual(viewModel.messages.map(\.content), ["existing"])
        viewModel.selectConversation("c1")
        XCTAssertEqual(viewModel.messages.map(\.content), ["hello", "reply"])
    }

    func testSwitchingConversationWhileStreaming_scopesPresentationToOriginMessage() async {
        let replyStream = ControlledReplyStream()
        let viewModel = ChatViewModel(
            sendToAI: { _, _, _ in replyStream.stream },
            getAIStatus: { .ready }
        )
        let first = ConversationThread(id: "c1", type: .single, participantIds: [], title: "First")
        let secondMessage = ChatMessage(role: .assistant, content: "existing")
        let second = ConversationThread(id: "c2", type: .single, participantIds: [], title: "Second")
        viewModel.loadConversations([first, second])
        viewModel.loadMessages(for: "c2", messages: [secondMessage])

        viewModel.inputText = "hello"
        viewModel.sendMessage()
        await waitUntil {
            viewModel.isStreaming && viewModel.messages.count == 2 && replyStream.isReady
        }

        guard let originMessageId = viewModel.messages.last?.id else {
            XCTFail("Expected a streaming assistant message")
            return
        }
        XCTAssertEqual(viewModel.activeStreamingConversationId, "c1")
        XCTAssertEqual(viewModel.activeStreamingMessageId, originMessageId)
        XCTAssertTrue(viewModel.isCurrentConversationStreaming)
        XCTAssertTrue(viewModel.isStreaming(messageId: originMessageId, in: "c1"))

        viewModel.selectConversation("c2")

        XCTAssertTrue(viewModel.isStreaming, "the origin request should continue in the background")
        XCTAssertEqual(viewModel.activeStreamingConversationId, "c1")
        XCTAssertFalse(viewModel.isCurrentConversationStreaming)
        XCTAssertFalse(viewModel.isStreaming(messageId: secondMessage.id, in: "c2"))

        viewModel.selectConversation("c1")

        XCTAssertTrue(viewModel.isCurrentConversationStreaming)
        XCTAssertTrue(viewModel.isStreaming(messageId: originMessageId, in: "c1"))

        viewModel.cancelStreaming()
        await waitUntil { !viewModel.isStreaming && replyStream.isTerminated }
        XCTAssertNil(viewModel.activeStreamingConversationId)
        XCTAssertNil(viewModel.activeStreamingMessageId)
        XCTAssertFalse(viewModel.isCurrentConversationStreaming)
    }

    func testDeletingOriginConversationWhileStreaming_doesNotResurrectIt() async {
        let replyStream = ControlledReplyStream()
        let viewModel = ChatViewModel(
            sendToAI: { _, _, _ in replyStream.stream },
            getAIStatus: { .ready }
        )
        let first = ConversationThread(id: "c1", type: .single, participantIds: [], title: "First")
        let second = ConversationThread(id: "c2", type: .single, participantIds: [], title: "Second")
        viewModel.loadConversations([first, second])
        viewModel.loadMessages(
            for: "c2",
            messages: [ChatMessage(role: .assistant, content: "existing")]
        )

        viewModel.inputText = "hello"
        viewModel.sendMessage()
        await waitUntil {
            viewModel.isStreaming && viewModel.messages.count == 2 && replyStream.isReady
        }

        viewModel.deleteConversation("c1")
        replyStream.yield("late reply")
        replyStream.finish()
        await waitUntil { !viewModel.isStreaming }

        XCTAssertEqual(viewModel.conversations.map(\.id), ["c2"])
        XCTAssertEqual(viewModel.selectedConversationId, "c2")
        XCTAssertEqual(viewModel.messages.map(\.content), ["existing"])
    }

    func testCancelStreaming_terminatesSourceWithoutReportingAReply() async {
        let replyStream = ControlledReplyStream()
        var didReportReply = false
        let viewModel = ChatViewModel(
            sendToAI: { _, _, _ in replyStream.stream },
            getAIStatus: { .ready }
        )
        viewModel.onAssistantReplied = { _, _ in
            didReportReply = true
        }
        viewModel.inputText = "hello"
        viewModel.sendMessage()
        await waitUntil {
            viewModel.isStreaming && viewModel.messages.count == 2 && replyStream.isReady
        }

        viewModel.cancelStreaming()
        await waitUntil { !viewModel.isStreaming && replyStream.isTerminated }

        XCTAssertFalse(didReportReply)
        XCTAssertEqual(viewModel.messages.map(\.content), ["hello"])
    }

    func testStreamingSnapshots_doNotReplaceLargeSettledHistoryUntilFinalCommit() async {
        let replyStream = ControlledReplyStream()
        var callbackCount = 0
        let viewModel = ChatViewModel(
            sendToAI: { _, _, _ in replyStream.stream },
            getAIStatus: { .ready }
        )
        let thread = ConversationThread(id: "c1", type: .single, participantIds: [], title: "First")
        let history = (0..<500).map { ChatMessage(role: .user, content: "history \($0)") }
        viewModel.loadConversations([thread])
        viewModel.loadMessages(for: "c1", messages: history)
        viewModel.onAssistantReplied = { _, _ in callbackCount += 1 }

        viewModel.inputText = "hello"
        viewModel.sendMessage()
        await waitUntil {
            viewModel.isStreaming && viewModel.messages.count == 502 && replyStream.isReady
        }
        let revisionAfterPlaceholder = viewModel.settledMessagesRevision
        guard let settledPlaceholder = viewModel.messages.last else {
            XCTFail("Expected an assistant placeholder")
            return
        }

        var expectedDraft = ""
        for chunk in ["one", " two", " three"] {
            if !expectedDraft.isEmpty {
                try? await Task.sleep(for: .milliseconds(60))
            }
            expectedDraft += chunk
            replyStream.yield(chunk)
            await waitUntil { viewModel.currentStreamingDraftContent == expectedDraft }
            XCTAssertEqual(viewModel.settledMessagesRevision, revisionAfterPlaceholder)
            XCTAssertEqual(viewModel.messages.last?.content, "")
        }

        XCTAssertEqual(
            viewModel.presentedMessage(settledPlaceholder, in: "c1").content,
            expectedDraft
        )

        replyStream.finish()
        await waitUntil { !viewModel.isStreaming }

        XCTAssertEqual(viewModel.settledMessagesRevision, revisionAfterPlaceholder + 1)
        XCTAssertEqual(viewModel.messages.last?.content, expectedDraft)
        XCTAssertEqual(callbackCount, 1)
    }

    func testStreamingDraft_isHiddenWhenAnotherConversationIsSelected() async {
        let replyStream = ControlledReplyStream()
        let viewModel = ChatViewModel(
            sendToAI: { _, _, _ in replyStream.stream },
            getAIStatus: { .ready }
        )
        let first = ConversationThread(id: "c1", type: .single, participantIds: [], title: "First")
        let second = ConversationThread(id: "c2", type: .single, participantIds: [], title: "Second")
        let secondMessage = ChatMessage(role: .assistant, content: "settled second")
        viewModel.loadConversations([first, second])
        viewModel.loadMessages(for: "c2", messages: [secondMessage])

        viewModel.inputText = "hello"
        viewModel.sendMessage()
        await waitUntil {
            viewModel.isStreaming && viewModel.messages.count == 2 && replyStream.isReady
        }
        guard let originPlaceholder = viewModel.messages.last else {
            XCTFail("Expected an assistant placeholder")
            return
        }
        replyStream.yield("partial")
        await waitUntil { viewModel.currentStreamingDraftContent == "partial" }
        XCTAssertEqual(viewModel.presentedMessage(originPlaceholder, in: "c1").content, "partial")

        viewModel.selectConversation("c2")

        XCTAssertNil(viewModel.currentStreamingDraftContent)
        XCTAssertEqual(viewModel.messages, [secondMessage])
        XCTAssertEqual(viewModel.presentedMessage(secondMessage, in: "c2"), secondMessage)

        viewModel.selectConversation("c1")
        XCTAssertEqual(viewModel.currentStreamingDraftContent, "partial")
        XCTAssertEqual(viewModel.presentedMessage(originPlaceholder, in: "c1").content, "partial")

        viewModel.cancelStreaming()
        await waitUntil { !viewModel.isStreaming && replyStream.isTerminated }
    }

    func testCancelStreaming_withPartialDraftCommitsOnceWithoutReplyCallback() async {
        let replyStream = ControlledReplyStream()
        var callbackCount = 0
        let viewModel = ChatViewModel(
            sendToAI: { _, _, _ in replyStream.stream },
            getAIStatus: { .ready }
        )
        let thread = ConversationThread(id: "c1", type: .single, participantIds: [], title: "First")
        viewModel.loadConversations([thread])
        viewModel.onAssistantReplied = { _, _ in callbackCount += 1 }
        viewModel.inputText = "hello"
        viewModel.sendMessage()
        await waitUntil {
            viewModel.isStreaming && viewModel.messages.count == 2 && replyStream.isReady
        }
        replyStream.yield("partial")
        await waitUntil { viewModel.currentStreamingDraftContent == "partial" }
        let revisionBeforeCancel = viewModel.settledMessagesRevision

        viewModel.cancelStreaming()
        await waitUntil { !viewModel.isStreaming && replyStream.isTerminated }

        XCTAssertEqual(viewModel.settledMessagesRevision, revisionBeforeCancel + 1)
        XCTAssertEqual(viewModel.messages.map(\.content), ["hello", "partial"])
        XCTAssertEqual(viewModel.conversations.first?.lastMessage, "partial")
        XCTAssertEqual(callbackCount, 0)
    }

    func testStopAcceptingWork_waitsForAcceptedSlashCommandAndRejectsLateInput() async {
        let blocker = SlashCommandBlocker()
        let viewModel = ChatViewModel()
        viewModel.onSlashCommand = { _, _ in
            await blocker.run()
            return true
        }
        viewModel.inputText = "/remember accepted"
        viewModel.sendMessage()
        await blocker.waitUntilStarted()

        let stopTask = Task { @MainActor in
            await viewModel.stopAcceptingWorkAndWait()
            await blocker.markStopReturned()
        }
        await Task.yield()

        let countBeforeLateInput = viewModel.messages.count
        viewModel.inputText = "/remember late"
        viewModel.sendMessage()
        let didStopBeforeRelease = await blocker.didStopReturn
        XCTAssertFalse(didStopBeforeRelease)
        XCTAssertEqual(viewModel.messages.count, countBeforeLateInput)

        await blocker.release()
        await stopTask.value
        let didStopAfterRelease = await blocker.didStopReturn
        XCTAssertTrue(didStopAfterRelease)
    }

    func testInputText_defaultIsEmpty() {
        let viewModel = ChatViewModel()

        XCTAssertEqual(viewModel.inputText, "")
    }

    func testAddAssistantMessage_preservesPetMetadata() {
        let viewModel = ChatViewModel()
        let petId = UUID()

        viewModel.addAssistantMessage("Hi", petId: petId, petName: "Mochi")

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].role, .assistant)
        XCTAssertEqual(viewModel.messages[0].petId, petId)
        XCTAssertEqual(viewModel.messages[0].petName, "Mochi")
    }

    private func wait(for viewModel: ChatViewModel, count: Int, timeout: TimeInterval = 1.0) {
        let start = Date()
        while viewModel.messages.count < count && Date().timeIntervalSince(start) < timeout {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        XCTAssertGreaterThanOrEqual(viewModel.messages.count, count)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private actor SlashCommandBlocker {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var didStopReturn = false

    func run() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func markStopReturned() {
        didStopReturn = true
    }
}

private final class ControlledReplyStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var conversationId: String?
    private var terminated = false

    lazy var stream = AsyncThrowingStream<String, Error> { continuation in
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.terminated = true
            self.lock.unlock()
        }
    }

    func yield(_ chunk: String) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(chunk)
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.finish()
    }

    func record(conversationId: String) {
        lock.lock()
        self.conversationId = conversationId
        lock.unlock()
    }

    var requestedConversationId: String? {
        lock.lock()
        let conversationId = conversationId
        lock.unlock()
        return conversationId
    }

    var isReady: Bool {
        lock.lock()
        let isReady = continuation != nil
        lock.unlock()
        return isReady
    }

    var isTerminated: Bool {
        lock.lock()
        let terminated = terminated
        lock.unlock()
        return terminated
    }
}
