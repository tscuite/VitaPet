import SwiftUI

@MainActor
public struct MessageBubble: View, Equatable {
    let message: ChatMessage
    let isStreaming: Bool
    let showsThinking: Bool
    @State private var thinkingExpanded: Bool = true

    nonisolated public static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.isStreaming == rhs.isStreaming
            && lhs.showsThinking == rhs.showsThinking
    }

    public init(message: ChatMessage, isStreaming: Bool = false, showsThinking: Bool = true) {
        self.message = message
        self.isStreaming = isStreaming
        self.showsThinking = showsThinking
    }

    public var body: some View {
        let parsedContent = ChatMessageParser.parse(message.content)

        HStack(alignment: .top, spacing: 0) {
            if isUserMessage {
                Spacer(minLength: 56)
            }

            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
                if showsPetHeader, let petName = message.petName {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(petAccentColor)
                            .frame(width: 7, height: 7)
                        Text(petName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(petAccentColor)
                    }
                    .padding(.horizontal, 4)
                }

                if showsThinking, let thinking = parsedContent.thinking {
                    thinkingDisclosure(thinking: thinking)
                }

                bubble(reply: parsedContent.reply)

                Text(timestampText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 460, alignment: isUserMessage ? .trailing : .leading)

            if !isUserMessage {
                Spacer(minLength: 56)
            }
        }
    }

    private func bubble(reply: String) -> some View {
        Text(verbatim: reply.isEmpty ? " " : reply)
            .textSelection(.enabled)
            .foregroundStyle(foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: isUserMessage ? Color.blue.opacity(0.15) : Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
            .overlay(alignment: isUserMessage ? .bottomTrailing : .bottomLeading) {
                if isStreaming {
                    StreamingCursor()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
    }

    private func thinkingDisclosure(thinking: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    thinkingExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: thinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("💭 思考过程")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if thinkingExpanded {
                Text(verbatim: thinking)
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isUserMessage: Bool { message.role == .user }

    private var showsPetHeader: Bool {
        message.role == .assistant && (message.petName?.isEmpty == false)
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return Color(nsColor: .quaternaryLabelColor).opacity(0.18)
        case .system:
            return Color(nsColor: .tertiaryLabelColor).opacity(0.18)
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : .primary
    }

    private var petAccentColor: Color {
        guard let petId = message.petId else { return .secondary }
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint]
        return colors[abs(petId.hashValue) % colors.count]
    }

    private var timestampText: String {
        message.timestamp.formatted(date: .omitted, time: .shortened)
    }
}

private struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        Circle()
            .fill(Color.secondary.opacity(0.8))
            .frame(width: 6, height: 6)
            .opacity(visible ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}
