enum SettingsScope: String, CaseIterable, Identifiable {
    case all
    case pet
    case sprite
    case awareness
    case ai
    case notifications
    case plugins
    case capability

    static let initial: SettingsScope = .all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .pet: return "宠物"
        case .sprite: return "外观"
        case .awareness: return "感知"
        case .ai: return "AI"
        case .notifications: return "通知"
        case .plugins: return "插件"
        case .capability: return "能力"
        }
    }

    /// SF Symbol used for the sidebar entry and the scope picker.
    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .pet: return "pawprint.fill"
        case .sprite: return "paintpalette"
        case .awareness: return "eye"
        case .ai: return "sparkles"
        case .notifications: return "bell.fill"
        case .plugins: return "puzzlepiece.extension"
        case .capability: return "lock.shield"
        }
    }

    func includes(_ section: SettingsScope) -> Bool {
        self == .all || self == section
    }
}
