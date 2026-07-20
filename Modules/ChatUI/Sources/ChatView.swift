import Foundation
import Localization
import SwiftUI

@MainActor
public struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @AppStorage("chat.showThinking") private var showThinking: Bool = true
    @State private var chatAppearance: ChatAppearanceSettings
    private let onSaveChatAppearance: @MainActor (Bool, Double) -> Void

    public init(
        viewModel: ChatViewModel = ChatViewModel(),
        chatAppearance: ChatAppearanceSettings = ChatAppearanceSettings(),
        onSaveChatAppearance: @escaping @MainActor (Bool, Double) -> Void = { _, _ in }
    ) {
        self.viewModel = viewModel
        _chatAppearance = State(initialValue: chatAppearance)
        self.onSaveChatAppearance = onSaveChatAppearance
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                headerCard

                if case .notConfigured = viewModel.aiStatus {
                    statusBanner(
                        text: L10n.chatStatusNotConfigured,
                        color: Color.orange.opacity(0.18),
                        borderColor: Color.orange.opacity(0.4)
                    )
                }

                messageSurface

                inputBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                showThinking.toggle()
            } label: {
                Image(systemName: showThinking ? "brain" : "brain.head.profile")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(showThinking ? Color.accentColor : Color.secondary)
                    .frame(width: 38, height: 38)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(showThinking ? "隐藏思考过程" : "显示思考过程")

            TextField(inputPlaceholderText, text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1 ... 8)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                }
                .disabled(sendDisabled)

            Button {
                if viewModel.isStreaming {
                    viewModel.cancelStreaming()
                } else {
                    viewModel.sendMessage()
                }
            } label: {
                Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(sendActionEnabled ? Color.white : Color.secondary)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(
                                sendActionEnabled
                                    ? AnyShapeStyle(viewModel.isStreaming ? Color.red : Color.accentColor)
                                    : AnyShapeStyle(Color.black.opacity(0.06))
                            )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!sendActionEnabled)
            .help(viewModel.isStreaming ? "停止生成 (⌘⏎)" : L10n.chatSend + " (⌘⏎)")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var headerCard: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(conversationAccentColor.opacity(0.9))

                if currentConversationType == .group {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    CatFaceGlyph(color: .white)
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(currentConversationTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(currentConversationSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            chatOpacityControl
            aiStatusBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var chatOpacityControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chatAppearance.translucencyEnabled ? Color.accentColor : Color.secondary)

            Slider(
                value: Binding(
                    get: {
                        ChatAppearanceSettings.directOpacityControlValue(
                            translucencyEnabled: chatAppearance.translucencyEnabled,
                            opacity: chatAppearance.opacity
                        )
                    },
                    set: { newValue in
                        updateChatAppearanceFromDirectOpacityControl(newValue)
                    }
                ),
                in: ChatAppearanceSettings.minimumOpacity...ChatAppearanceSettings.maximumOpacity,
                step: 0.05
            )
            .controlSize(.small)
            .frame(width: 104)

            Text("\(Int((ChatAppearanceSettings.directOpacityControlValue(translucencyEnabled: chatAppearance.translucencyEnabled, opacity: chatAppearance.opacity) * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .help("拖动调整聊天窗口透明度")
    }

    private var messageSurface: some View {
        ChatMessageSurface(viewModel: viewModel)
    }

    @ViewBuilder
    private var aiStatusBadge: some View {
        let config = aiStatusVisual
        HStack(spacing: 8) {
            Circle()
                .fill(config.tint)
                .frame(width: 8, height: 8)
            Text(config.title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(config.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(config.background, in: Capsule())
    }

    private var aiStatusVisual: (title: String, tint: Color, background: Color) {
        switch viewModel.aiStatus {
        case .ready:
            return ("已连接", .green, Color.green.opacity(0.12))
        case .connecting:
            return ("连接中", .orange, Color.orange.opacity(0.12))
        case .error:
            return ("错误", .red, Color.red.opacity(0.12))
        case .notConfigured:
            return ("未配置", .orange, Color.orange.opacity(0.12))
        }
    }

    private var currentThread: ConversationThread? {
        viewModel.conversations.first { $0.id == viewModel.selectedConversationId }
    }

    private var currentConversationType: ConversationType {
        currentThread?.type ?? .single
    }

    private var currentConversationTitle: String {
        guard let currentThread else {
            return "VitaPet"
        }
        if currentThread.title.isEmpty {
            return currentThread.type == .group ? L10n.chatGroupChat : L10n.chatSingleChat
        }
        return currentThread.title
    }

    private var currentConversationSubtitle: String {
        let prefix = currentConversationType == .group ? "多宠会话" : "单宠会话"
        if viewModel.isStreaming {
            return "\(prefix) · 正在回复…"
        }
        let messageCount = viewModel.messages.count
        return "\(prefix) · \(messageCount) 条消息"
    }

    private func updateChatAppearance(translucencyEnabled: Bool, opacity: Double) {
        let settings = ChatAppearanceSettings(
            translucencyEnabled: translucencyEnabled,
            opacity: opacity
        )
        chatAppearance = settings
        onSaveChatAppearance(settings.translucencyEnabled, settings.opacity)
    }

    private func updateChatAppearanceFromDirectOpacityControl(_ opacity: Double) {
        let settings = ChatAppearanceSettings.settingsFromDirectOpacityControl(opacity)
        updateChatAppearance(
            translucencyEnabled: settings.translucencyEnabled,
            opacity: settings.opacity
        )
    }

    private var sendDisabled: Bool { viewModel.isStreaming }

    private var sendButtonEnabled: Bool {
        !sendDisabled && !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendActionEnabled: Bool {
        viewModel.isStreaming || sendButtonEnabled
    }

    private var inputPlaceholderText: String {
        viewModel.isStreaming ? L10n.chatStreamingPlaceholder : L10n.chatInputPlaceholder
    }

    private var conversationAccentColor: Color {
        currentConversationType == .group ? .orange : .blue
    }

    @ViewBuilder
    private func statusBanner(text: String, color: Color, borderColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

}

@MainActor
private struct ChatMessageSurface: View {
    @Bindable var viewModel: ChatViewModel
    @State private var lastStreamingScrollAt: Date = .distantPast

    private let bottomAnchorId = "chat-bottom-anchor"
    private let minStreamingScrollInterval: TimeInterval = 0.12

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if viewModel.messages.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        let lastId = viewModel.messages.last?.id
                        let streamingId = viewModel.isStreaming ? lastId : nil
                        ForEach(viewModel.messages) { message in
                            MessageBubble(
                                message: message,
                                isStreaming: streamingId == message.id && message.role == .assistant,
                                showsThinking: viewModel.showsThinking(for: message.id)
                            )
                            .equatable()
                            .id(message.id)
                        }
                        Color.clear.frame(height: 4).id(bottomAnchorId)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .contentMargins(.top, 12, for: .scrollContent)
            .contentMargins(.bottom, 8, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy: proxy, animated: !viewModel.isStreaming)
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                scrollToBottomForStreamingIfNeeded(proxy: proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, isStreaming in
                if isStreaming {
                    lastStreamingScrollAt = .distantPast
                } else {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
            .onAppear {
                scrollToBottom(proxy: proxy, animated: false)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let target = AnyHashable(bottomAnchorId)
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    private func scrollToBottomForStreamingIfNeeded(proxy: ScrollViewProxy) {
        guard viewModel.isStreaming else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastStreamingScrollAt) >= minStreamingScrollInterval else {
            return
        }
        lastStreamingScrollAt = now
        scrollToBottom(proxy: proxy, animated: false)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.accentColor.opacity(0.88))
                .frame(width: 82, height: 82)
                .overlay {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }

            VStack(spacing: 6) {
                Text("开始一段对话")
                    .font(.title3.weight(.semibold))
                Text(emptyStateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                emptyStateChip(title: "总结日程", symbolName: "calendar")
                emptyStateChip(title: "写一句状态", symbolName: "sparkles")
                emptyStateChip(title: "陪宠物聊天", symbolName: "pawprint.fill")
            }
        }
        .padding(.horizontal, 32)
    }

    private var emptyStateText: String {
        if case .notConfigured = viewModel.aiStatus {
            return L10n.chatEmptyNotConfigured
        }
        return L10n.chatEmptyNewConversation
    }

    private func emptyStateChip(title: String, symbolName: String) -> some View {
        Label(title, systemImage: symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.05), in: Capsule())
    }
}
