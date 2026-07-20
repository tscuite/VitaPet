import Foundation
import Localization

enum SettingsSectionID: String, CaseIterable, Hashable, Sendable {
    case petManagement
    case spritePacks
    case chatAppearance
    case desktopAwareness
    case weatherAwareness
    case sound
    case aiConfiguration
    case remoteMemory
    case notifications
    case plugins
    case capabilities

    var scope: SettingsScope {
        switch self {
        case .petManagement:
            return .pet
        case .spritePacks, .chatAppearance:
            return .sprite
        case .desktopAwareness, .weatherAwareness, .sound:
            return .awareness
        case .aiConfiguration, .remoteMemory:
            return .ai
        case .notifications:
            return .notifications
        case .plugins:
            return .plugins
        case .capabilities:
            return .capability
        }
    }

    /// Computed so a runtime locale change is reflected by the next search.
    var searchableTerms: [String] {
        switch self {
        case .petManagement:
            return [
                L10n.settingsPetManagement,
                L10n.settingsPetManagementName,
                L10n.settingsPetManagementAppearance,
                L10n.settingsPetManagementSize,
                L10n.settingsPetManagementGender,
                L10n.settingsPetManagementGenderNeutral,
                L10n.settingsPetManagementGenderMale,
                L10n.settingsPetManagementGenderFemale,
                L10n.settingsPetManagementAge,
                L10n.settingsPetManagementPersonality,
                L10n.settingsPetManagementHobbies,
                L10n.settingsPetManagementEdit,
                L10n.settingsPetManagementSave,
                L10n.settingsPetManagementCancel,
                L10n.settingsPetManagementDelete,
                L10n.settingsPetManagementAdd,
                L10n.settingsPetManagementMaxReached,
                "宠物管理", "宠物", "名称", "外观", "大小", "性别", "年龄", "性格", "爱好",
                "气泡文字", "独立音效", "重置", "pet", "profile", "personality", "hobbies",
            ]
        case .spritePacks:
            return [
                L10n.settingsSpritePacks,
                L10n.settingsSpritePacksImport,
                L10n.settingsSpritePacksCreateTemplate,
                L10n.settingsSpritePacksExport,
                L10n.settingsSpritePacksRevealFinder,
                L10n.settingsSpritePacksDelete,
                L10n.settingsSpritePacksStatesCount,
                L10n.settingsSpritePacksFramesCount,
                L10n.settingsSpritePacksBuiltIn,
                "外观包", "精灵包", "素材包", "导入", "模板", "sprite pack", "appearance pack",
            ]
        case .chatAppearance:
            return [
                "聊天窗口", "聊天外观", "半透明", "透明度", "chat window", "opacity", "translucency",
            ]
        case .desktopAwareness:
            return [
                "桌面感知", "应用感知", "应用类别", "Bundle ID", "分类", "动画", "气泡文案", "规则",
                "间隔", "添加规则", "desktop awareness", "application rule", "interval",
            ]
        case .weatherAwareness:
            return [
                "天气感知", "天气", "位置", "坐标", "纬度", "经度", "刷新间隔", "weather",
                "latitude", "longitude",
            ]
        case .sound:
            return ["音效", "声音", "音量", "sound", "volume"]
        case .aiConfiguration:
            return [
                L10n.settingsAI,
                L10n.settingsAIBackend,
                L10n.settingsAIBackendOllama,
                L10n.settingsAIBackendOpenAICompatible,
                L10n.settingsAIEndpoint,
                L10n.settingsAIModel,
                L10n.settingsAITestConnection,
                L10n.settingsAISystemPrompt,
                L10n.settingsAIStatusReady,
                L10n.settingsAIStatusNotConfigured,
                L10n.settingsAIStatusConnecting,
                L10n.settingsAIStatusError,
                "AI 配置", "大模型", "Ollama", "OpenAI", "API 密钥", "MCP", "系统提示词",
                "模型服务", "chat completions",
            ]
        case .remoteMemory:
            return [
                "远程记忆", "长期记忆", "多设备", "Worker", "召回", "用户标识", "命名空间",
                "服务地址", "鉴权", "令牌", "用户名", "密码", "测试读取", "测试写入",
                "Subject", "Scope", "Bearer", "Basic", "remote memory",
            ]
        case .notifications:
            return [
                L10n.settingsNotifications,
                L10n.settingsNotificationsGithub,
                L10n.settingsNotificationsGithubToken,
                L10n.settingsNotificationsGithubTokenPlaceholder,
                L10n.settingsNotificationsWebhook,
                L10n.settingsNotificationsWebhookEnabled,
                L10n.settingsNotificationsWebhookPort,
                L10n.settingsNotificationsWebhookHint,
                "通知", "GitHub", "Token", "Webhook", "Port", "Secret", "notification",
            ]
        case .plugins:
            return [
                L10n.settingsPlugins,
                "插件", "触发规则", "创建插件", "卸载插件", "JSON 插件", "在 Finder 中显示",
                "plugin", "extension",
            ]
        case .capabilities:
            return [
                L10n.settingsCapabilities,
                "能力", "权限", "capability", "permission",
            ]
        }
    }
}

enum SettingsSearchMatcher {
    static func visibleSections(
        selectedScope: SettingsScope,
        query: String,
        dynamicMatches: Set<SettingsSectionID> = []
    ) -> Set<SettingsSectionID> {
        let keyword = normalized(query)
        guard !keyword.isEmpty else {
            return Set(SettingsSectionID.allCases.filter { selectedScope.includes($0.scope) })
        }

        return Set(SettingsSectionID.allCases.filter { section in
            matches(keyword, in: section.searchableTerms) || dynamicMatches.contains(section)
        })
    }

    static func matchingIndices<Row>(
        in rows: [Row],
        query: String,
        parent: SettingsSectionID,
        searchableFields: (Row) -> [String],
        preserve: (Row) -> Bool = { _ in false }
    ) -> [Int] {
        let keyword = normalized(query)
        guard !keyword.isEmpty, !matches(keyword, in: parent.searchableTerms) else {
            return Array(rows.indices)
        }

        return rows.indices.filter { index in
            let row = rows[index]
            return preserve(row) || matches(keyword, in: searchableFields(row))
        }
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ keyword: String, in fields: [String]) -> Bool {
        fields.contains { $0.localizedCaseInsensitiveContains(keyword) }
    }
}
