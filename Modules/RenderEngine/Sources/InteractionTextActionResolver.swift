import Foundation

public struct InteractionTextAction: Equatable, Sendable {
    public let displayText: String
    public let state: AnimationState
    public let count: Int

    public init(displayText: String, state: AnimationState, count: Int = 1) {
        self.displayText = displayText
        self.state = state
        self.count = max(1, min(count, 8))
    }
}

public enum InteractionTextActionResolver {
    private struct KeywordRule {
        let phrases: [String]
        let state: AnimationState
    }

    private static let actionTagPattern = #"\[ACTION:([^\]:]+)(?::(\d+))?\]"#

    private static let doubleClickRules: [KeywordRule] = [
        KeywordRule(phrases: ["转圈", "圈圈", "spin", "happycircle", "happy spin"], state: .joySpinCombo),
        KeywordRule(phrases: ["翻跟头", "空翻", "翻滚", "somersault", "flip"], state: .somersaultCombo),
        KeywordRule(phrases: ["跑酷", "parkour"], state: .parkourCombo),
        KeywordRule(phrases: ["打拳", "拳击", "连拳", "boxing", "punch"], state: .boxingCombo),
        KeywordRule(phrases: ["派对", "party"], state: .partyCombo),
        KeywordRule(phrases: ["训练", "training"], state: .trainingCombo),
        KeywordRule(phrases: ["跳舞", "舞蹈", "dance"], state: .danceCombo),
        KeywordRule(phrases: ["抱抱", "贴贴", "蹭蹭", "摸摸头", "摸头", "撒娇", "nuzzle", "hug", "cuddle"], state: .nuzzle),
        KeywordRule(phrases: ["喜欢", "爱你", "爱", "love", "亲亲", "亲一口", "heart", "❤", "❤️"], state: .love),
        KeywordRule(phrases: ["朋友", "你好", "嗨", "hi", "hello", "招手", "wave"], state: .wave),
        KeywordRule(phrases: ["尾巴", "摇尾", "tail"], state: .tailWag),
        KeywordRule(phrases: ["求求", "拜托", "要嘛", "please", "beg"], state: .beg),
        KeywordRule(phrases: ["害羞", "脸红", "羞", "blush"], state: .blush),
        KeywordRule(phrases: ["骄傲", "得意", "最棒", "厉害", "棒", "proud"], state: .proud),
        KeywordRule(phrases: ["闪亮", "闪闪", "星星", "sparkle"], state: .sparkle),
        KeywordRule(phrases: ["开心", "高兴", "快乐", "cheer"], state: .cheer),
        KeywordRule(phrases: ["嘻嘻", "嘿嘿", "玩", "play", "逗"], state: .play),
        KeywordRule(phrases: ["蹦", "跳", "bounce"], state: .bounce),
        KeywordRule(phrases: ["点头", "嗯嗯", "好的", "好呀", "nod"], state: .nod),
        KeywordRule(phrases: ["摇头", "不要", "不行", "headshake"], state: .headShake),
        KeywordRule(phrases: ["唱歌", "唱", "sing"], state: .sing),
        KeywordRule(phrases: ["咖啡", "coffee"], state: .coffee),
        KeywordRule(phrases: ["喝", "口渴", "drink"], state: .drink),
        KeywordRule(phrases: ["饿", "吃", "饭", "snack", "eat"], state: .eat),
        KeywordRule(phrases: ["哈欠", "yawn"], state: .yawn),
        KeywordRule(phrases: ["困", "睡", "累", "sleep"], state: .sleep),
        KeywordRule(phrases: ["吓", "惊讶", "震惊", "surprised"], state: .surprised),
        KeywordRule(phrases: ["想", "思考", "think"], state: .think),
        KeywordRule(phrases: ["礼物", "gift"], state: .gift),
        KeywordRule(phrases: ["读书", "看书", "read"], state: .read),
        KeywordRule(phrases: ["写", "write"], state: .write),
        KeywordRule(phrases: ["电话", "phone"], state: .phone),
        KeywordRule(phrases: ["听", "listen"], state: .listen),
        KeywordRule(phrases: ["生气", "angry"], state: .angry),
        KeywordRule(phrases: ["难过", "sad"], state: .sad),
        KeywordRule(phrases: ["害怕", "scared"], state: .scared),
        KeywordRule(phrases: ["迷糊", "confused"], state: .confused),
        KeywordRule(phrases: ["偷看", "peek"], state: .peek),
    ]

    public static func resolveDoubleClickText(_ text: String) -> InteractionTextAction {
        let cleanedText = displayTextByRemovingActionTags(from: text)
        if let explicitAction = firstExplicitAction(in: text) {
            return InteractionTextAction(
                displayText: cleanedText,
                state: explicitAction.state,
                count: explicitAction.count
            )
        }

        return InteractionTextAction(
            displayText: cleanedText,
            state: keywordState(for: text) ?? .react
        )
    }

    private static func keywordState(for text: String) -> AnimationState? {
        let normalizedText = text.lowercased()
        return doubleClickRules.first { rule in
            rule.phrases.contains { normalizedText.contains($0.lowercased()) }
        }?.state
    }

    private static func firstExplicitAction(in text: String) -> (state: AnimationState, count: Int)? {
        guard let regex = try? NSRegularExpression(pattern: actionTagPattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            guard let actionRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            let actionName = String(text[actionRange])
            guard let state = ActionComboPlanner.playbackState(for: actionName) else {
                continue
            }

            let count: Int
            if match.numberOfRanges > 2,
               let countRange = Range(match.range(at: 2), in: text),
               let parsedCount = Int(text[countRange]) {
                count = max(1, min(parsedCount, 8))
            } else {
                count = 1
            }

            return (state, count)
        }

        return nil
    }

    private static func displayTextByRemovingActionTags(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: actionTagPattern) else {
            return cleanDisplayText(text)
        }

        let range = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let cleaned = cleanDisplayText(stripped)
        return cleaned.isEmpty ? "!" : cleaned
    }

    private static func cleanDisplayText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }
}
