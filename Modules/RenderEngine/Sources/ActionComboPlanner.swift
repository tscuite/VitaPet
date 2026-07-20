import Foundation

public struct ActionComboSegment: Equatable, Sendable {
    public let state: AnimationState
    public let duration: TimeInterval

    public init(state: AnimationState, duration: TimeInterval) {
        self.state = state
        self.duration = duration
    }
}

public struct ActionComboPlan: Equatable, Sendable {
    public let state: AnimationState
    public let segments: [ActionComboSegment]
    public let windowTravelPoints: Double

    public init(
        state: AnimationState,
        segments: [ActionComboSegment],
        windowTravelPoints: Double = 0
    ) {
        self.state = state
        self.segments = segments
        self.windowTravelPoints = windowTravelPoints
    }

    public var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }
}

public enum ActionComboPlanner {
    public static let comboStates: [AnimationState] = [
        .danceCombo,
        .somersaultCombo,
        .boxingCombo,
        .parkourCombo,
        .partyCombo,
        .trainingCombo,
        .joySpinCombo
    ]

    public static func comboState(for value: String) -> AnimationState? {
        let normalized = normalizedAlias(value)
        if let exactState = AnimationState(rawValue: value),
           let comboState = comboState(for: exactState) {
            return comboState
        }

        switch normalized {
        case "dance", "dancecombo", "dancechain", "danceroutine", "跳舞", "连舞", "舞蹈":
            return .danceCombo
        case "celebrate", "joyspin", "joyspincombo", "happyspin", "happycircle", "开心转圈圈", "开心到转圈圈", "转圈圈", "高兴转圈":
            return .joySpinCombo
        case "somersault", "somersaultcombo", "somersaultchain", "flipcombo", "flip", "acrobat", "翻跟头", "空翻", "翻滚":
            return .somersaultCombo
        case "boxing", "boxingcombo", "boxingchain", "punchcombo", "punch", "打拳", "拳击", "连拳":
            return .boxingCombo
        case "parkour", "parkourcombo", "跑酷", "跑酷连招":
            return .parkourCombo
        case "party", "partycombo", "派对", "派对表演":
            return .partyCombo
        case "training", "trainingcombo", "训练", "训练连招":
            return .trainingCombo
        default:
            return nil
        }
    }

    public static func comboState(for state: AnimationState) -> AnimationState? {
        switch state {
        case .celebrate:
            return .joySpinCombo
        case .dance:
            return .danceCombo
        case .somersault:
            return .somersaultCombo
        case .punch:
            return .boxingCombo
        default:
            return comboStates.contains(state) ? state : nil
        }
    }

    public static func playbackState(for value: String) -> AnimationState? {
        if let comboState = comboState(for: value) {
            return comboState
        }

        return AnimationState(rawValue: value)
    }

    public static func plan(for state: AnimationState, count: Int = 1) -> ActionComboPlan? {
        switch state {
        case .danceCombo:
            return ActionComboPlan(
                state: state,
                segments: [
                    .init(state: .dance, duration: 0.72),
                    .init(state: .slide, duration: 0.48),
                    .init(state: .spin, duration: 0.66),
                    .init(state: .tailWag, duration: 0.58),
                    .init(state: .sparkle, duration: 0.58),
                    .init(state: .proud, duration: 0.54)
                ]
            )
        case .joySpinCombo:
            return ActionComboPlan(
                state: state,
                segments: [
                    .init(state: .celebrate, duration: 0.44),
                    .init(state: .spin, duration: 0.86),
                    .init(state: .sparkle, duration: 0.58),
                    .init(state: .tailWag, duration: 0.50),
                    .init(state: .proud, duration: 0.48)
                ]
            )
        case .somersaultCombo:
            let flips = clampedCount(count)
            return ActionComboPlan(
                state: state,
                segments: [
                    .init(state: .crouch, duration: 0.34),
                    .init(state: .somersault, duration: 0.50 + Double(flips) * 0.55),
                    .init(state: .pawReach, duration: 0.36),
                    .init(state: .punch, duration: 0.38),
                    .init(state: .sparkle, duration: 0.54)
                ],
                windowTravelPoints: Double(flips) * 50
            )
        case .boxingCombo:
            return ActionComboPlan(
                state: state,
                segments: [
                    .init(state: .guardDuty, duration: 0.44),
                    .init(state: .pawTap, duration: 0.34),
                    .init(state: .pawReach, duration: 0.30),
                    .init(state: .punch, duration: 0.26),
                    .init(state: .pawReach, duration: 0.28),
                    .init(state: .punch, duration: 0.30),
                    .init(state: .guardDuty, duration: 0.42),
                    .init(state: .proud, duration: 0.46)
                ]
            )
        case .parkourCombo:
            return ActionComboPlan(
                state: state,
                segments: [
                    .init(state: .pounce, duration: 0.50),
                    .init(state: .slide, duration: 0.42),
                    .init(state: .roll, duration: 0.52),
                    .init(state: .spin, duration: 0.58),
                    .init(state: .land, duration: 0.30),
                    .init(state: .cheer, duration: 0.48)
                ],
                windowTravelPoints: 90
            )
        case .partyCombo:
            return ActionComboPlan(
                state: state,
                segments: [
                    .init(state: .sing, duration: 0.70),
                    .init(state: .dance, duration: 0.64),
                    .init(state: .sparkle, duration: 0.58),
                    .init(state: .cheer, duration: 0.42),
                    .init(state: .tailWag, duration: 0.50),
                    .init(state: .blush, duration: 0.46)
                ]
            )
        case .trainingCombo:
            return ActionComboPlan(
                state: state,
                segments: [
                    .init(state: .guardDuty, duration: 0.44),
                    .init(state: .crouch, duration: 0.34),
                    .init(state: .pounce, duration: 0.50),
                    .init(state: .pawTap, duration: 0.34),
                    .init(state: .boxingCombo, duration: 1.70),
                    .init(state: .proud, duration: 0.48)
                ]
            )
        default:
            return nil
        }
    }

    public static func manifestFrames(for state: AnimationState, prefix: String) -> [String]? {
        switch state {
        case .danceCombo:
            return [
                "\(prefix)_dance_0",
                "\(prefix)_slide_0",
                "\(prefix)_slide_1",
                "\(prefix)_spin_0",
                "\(prefix)_tailWag_0",
                "\(prefix)_tailWag_2",
                "\(prefix)_sparkle_0",
                "\(prefix)_sparkle_3",
                "\(prefix)_proud_0"
            ]
        case .joySpinCombo:
            return [
                "\(prefix)_celebrate_0",
                "\(prefix)_spin_0",
                "\(prefix)_sparkle_0",
                "\(prefix)_sparkle_2",
                "\(prefix)_tailWag_0",
                "\(prefix)_tailWag_3",
                "\(prefix)_proud_0"
            ]
        case .somersaultCombo:
            return [
                "\(prefix)_crouch_0",
                "\(prefix)_somersault_0",
                "\(prefix)_somersault_1",
                "\(prefix)_somersault_2",
                "\(prefix)_somersault_3",
                "\(prefix)_pawReach_0",
                "\(prefix)_sparkle_0",
                "\(prefix)_sparkle_3"
            ]
        case .boxingCombo:
            return [
                "\(prefix)_guard_0",
                "\(prefix)_guard_2",
                "\(prefix)_pawTap_0",
                "\(prefix)_pawReach_0",
                "\(prefix)_angry_0",
                "\(prefix)_pawReach_2",
                "\(prefix)_proud_0"
            ]
        case .parkourCombo:
            return [
                "\(prefix)_pounce_0",
                "\(prefix)_pounce_2",
                "\(prefix)_slide_0",
                "\(prefix)_slide_2",
                "\(prefix)_roll_0",
                "\(prefix)_spin_0",
                "\(prefix)_land_0",
                "\(prefix)_cheer_0"
            ]
        case .partyCombo:
            return [
                "\(prefix)_sing_0",
                "\(prefix)_sing_3",
                "\(prefix)_dance_0",
                "\(prefix)_sparkle_0",
                "\(prefix)_sparkle_3",
                "\(prefix)_cheer_0",
                "\(prefix)_tailWag_0",
                "\(prefix)_tailWag_3",
                "\(prefix)_blush_0"
            ]
        case .trainingCombo:
            return [
                "\(prefix)_guard_0",
                "\(prefix)_guard_2",
                "\(prefix)_crouch_0",
                "\(prefix)_pounce_0",
                "\(prefix)_pawTap_0",
                "\(prefix)_pawReach_0",
                "\(prefix)_angry_0",
                "\(prefix)_proud_0"
            ]
        default:
            return nil
        }
    }

    private static func clampedCount(_ count: Int) -> Int {
        max(1, min(count, 8))
    }

    private static func normalizedAlias(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
