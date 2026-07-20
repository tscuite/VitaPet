import Foundation
import Localization
import SwiftUI

@MainActor
struct ConversationListView: View {
    let conversations: [ConversationThread]
    let selectedId: String?
    let onSelect: (String) -> Void
    let onDelete: (String) -> Void
    let onCreateGroup: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            List {
                ForEach(conversations) { thread in
                    ConversationRow(thread: thread, isSelected: thread.id == selectedId)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(thread.id)
                        }
                        .contextMenu {
                            if thread.type == .group {
                                Button(L10n.chatDeleteConversation, role: .destructive) {
                                    onDelete(thread.id)
                                }
                            }
                        }
                }
            }
            .listRowSeparator(.hidden)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)

            VStack(spacing: 0) {
                Divider()
                    .opacity(0.4)
                Button(action: onCreateGroup) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.bubble.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(L10n.chatNewGroup)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(0.55)
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var groupCount: Int {
        conversations.filter { $0.type == .group }.count
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.88))

                    CatFaceGlyph(color: Color.white.opacity(0.94))
                        .padding(8)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("VitaPet")
                        .font(.title3.weight(.semibold))
                    Text("桌面宠物与本地模型对话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                metricChip(title: "\(conversations.count) 个会话", symbolName: "bubble.left.and.bubble.right.fill")
                metricChip(title: "\(groupCount) 个群组", symbolName: "person.3.fill")
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func metricChip(title: String, symbolName: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
            Text(title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.05), in: Capsule())
    }
}

struct ConversationRow: View {
    let thread: ConversationThread
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 42, height: 42)

                if thread.type == .group {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconForeground)
                } else {
                    CatFaceGlyph(color: iconForeground)
                        .frame(width: 26, height: 26)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title.isEmpty ? fallbackTitle : thread.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(timestampText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if thread.unreadCount > 0 {
                    Text("\(thread.unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.red, in: Capsule())
                } else {
                    Text(typeText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            Color.accentColor.opacity(0.14)
                        )
                        : AnyShapeStyle(Color(nsColor: .textBackgroundColor).opacity(0.55))
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.36) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        }
        .padding(.vertical, 3)
        .listRowBackground(Color.clear)
    }

    private var fallbackTitle: String {
        thread.type == .group ? L10n.chatGroupChat : L10n.chatSingleChat
    }

    private var previewText: String {
        if thread.lastMessage.isEmpty {
            return thread.type == .group ? "与多只宠物一起聊天" : "开始一段新的对话"
        }
        return thread.lastMessage
    }

    private var typeText: String {
        thread.type == .group ? "群聊" : "私聊"
    }

    private var timestampText: String {
        if Calendar.current.isDateInToday(thread.lastTimestamp) {
            return thread.lastTimestamp.formatted(date: .omitted, time: .shortened)
        }
        return thread.lastTimestamp.formatted(.dateTime.month(.abbreviated).day())
    }

    private var iconBackground: Color {
        thread.type == .group ? Color.orange.opacity(0.16) : Color.blue.opacity(0.16)
    }

    private var iconForeground: Color {
        thread.type == .group ? .orange : .blue
    }
}
