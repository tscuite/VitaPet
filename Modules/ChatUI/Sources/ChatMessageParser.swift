import Foundation

struct ParsedChatMessage: Equatable, Sendable {
    let thinking: String?
    let reply: String
}

enum ChatMessageParser {
    /// Splits canonical and partially streamed think-tag states into display fields.
    static func parse(_ text: String) -> ParsedChatMessage {
        let hasOpen = text.range(of: "<think>", options: .caseInsensitive) != nil
        let hasClose = text.range(of: "</think>", options: .caseInsensitive) != nil
        guard hasOpen || hasClose else {
            return ParsedChatMessage(thinking: nil, reply: text)
        }

        if let openRange = text.range(of: "<think>", options: .caseInsensitive) {
            if let closeRange = text.range(
                of: "</think>",
                options: .caseInsensitive,
                range: openRange.upperBound..<text.endIndex
            ) {
                let thinking = String(text[openRange.upperBound..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let before = String(text[text.startIndex..<openRange.lowerBound])
                let after = String(text[closeRange.upperBound..<text.endIndex])
                let reply = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
                return ParsedChatMessage(thinking: thinking.nilIfEmpty, reply: reply)
            }

            let reply = String(text[text.startIndex..<openRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let thinking = String(text[openRange.upperBound..<text.endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedChatMessage(thinking: thinking.nilIfEmpty, reply: reply)
        }

        if let closeRange = text.range(of: "</think>", options: .caseInsensitive) {
            let thinking = String(text[text.startIndex..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = String(text[closeRange.upperBound..<text.endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedChatMessage(thinking: thinking.nilIfEmpty, reply: reply)
        }

        return ParsedChatMessage(thinking: nil, reply: text)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
