import Foundation

public enum L10n {
    public static var locale: String {
        get { storage.locale }
        set { storage.locale = newValue }
    }

    public static var menuChat: String { tr("menu.chat") }
    public static var menuSettings: String { tr("menu.settings") }
    public static var menuActivityLog: String { tr("menu.activity_log") }
    public static var menuPetSize: String { tr("menu.pet_size") }
    public static var menuSizeSmall: String { tr("menu.size.small") }
    public static var menuSizeMedium: String { tr("menu.size.medium") }
    public static var menuSizeLarge: String { tr("menu.size.large") }
    public static var menuSizeExtraLarge: String { tr("menu.size.extra_large") }
    public static var menuHidePet: String { tr("menu.hide_pet") }
    public static var menuShowPet: String { tr("menu.show_pet") }
    public static var menuQuit: String { tr("menu.quit") }
    public static var menuAddPet: String { tr("menu.add_pet") }
    public static var menuRemovePet: String { tr("menu.remove_pet") }
    public static var menuStatistics: String { tr("menu.statistics") }
    public static var menuMiniGames: String { tr("menu.mini_games") }
    public static var menuNoMiniGames: String { tr("menu.no_mini_games") }
    public static var menuKeepOnePet: String { tr("menu.keep_one_pet") }
    public static var menuPomodoro: String { tr("menu.pomodoro") }
    public static var menuPomodoroIdle: String { tr("menu.pomodoro.idle") }
    public static var menuPomodoroStart: String { tr("menu.pomodoro.start") }
    public static var menuPomodoroPause: String { tr("menu.pomodoro.pause") }
    public static var menuPomodoroResume: String { tr("menu.pomodoro.resume") }
    public static var menuPomodoroReset: String { tr("menu.pomodoro.reset") }
    public static var menuPomodoroSkip: String { tr("menu.pomodoro.skip") }
    public static func menuPomodoroPaused(_ timeText: String) -> String {
        String(format: tr("menu.pomodoro.paused"), timeText)
    }
    public static func menuPomodoroWorking(_ timeText: String) -> String {
        String(format: tr("menu.pomodoro.working"), timeText)
    }
    public static func menuPomodoroBreak(_ timeText: String) -> String {
        String(format: tr("menu.pomodoro.break"), timeText)
    }
    public static func statusMoodHappy(_ happiness: Int) -> String {
        String(format: tr("status.mood.happy"), happiness)
    }
    public static func statusMoodNormal(_ happiness: Int) -> String {
        String(format: tr("status.mood.normal"), happiness)
    }
    public static func statusMoodSad(_ happiness: Int) -> String {
        String(format: tr("status.mood.sad"), happiness)
    }
    public static var gameCatch: String { tr("game.catch") }
    public static var gameRace: String { tr("game.race") }
    public static var gameHideAndSeek: String { tr("game.hide_and_seek") }
    public static var gameRockPaperScissors: String { tr("game.rock_paper_scissors") }
    public static var menuFeedPet: String { tr("menu.feed_pet") }
    public static var menuPlayWithPet: String { tr("menu.play_with_pet") }
    public static var menuPatPet: String { tr("menu.pat_pet") }
    public static var menuPetMood: String { tr("menu.pet_mood") }

    public static var bubbleTexts: [String] { trs("bubble.texts") }
    public static var bubbleDoubleClickTexts: [String] { trs("bubble.double_click_texts") }

    public static var settingsSpritePacks: String { tr("settings.sprite_packs") }
    public static var settingsAI: String { tr("settings.ai") }
    public static var settingsAIEndpoint: String { tr("settings.ai.endpoint") }
    public static var settingsAIBackend: String { tr("settings.ai.backend") }
    public static var settingsAIBackendOllama: String { tr("settings.ai.backend_ollama") }
    public static var settingsAIBackendOpenAICompatible: String { tr("settings.ai.backend_openai_compatible") }
    public static var settingsAIModel: String { tr("settings.ai.model") }
    public static var settingsAITestConnection: String { tr("settings.ai.test_connection") }
    public static var settingsAISystemPrompt: String { tr("settings.ai.system_prompt") }
    public static var settingsAISystemPromptPlaceholder: String { tr("settings.ai.system_prompt_placeholder") }
    public static var settingsAIProactiveEnabled: String { tr("settings.ai.proactive_enabled") }
    public static var settingsAIProactiveInterval: String { tr("settings.ai.proactive_interval") }
    public static var settingsAIMemoryEnabled: String { tr("settings.ai.memory_enabled") }
    public static var settingsAIClearMemory: String { tr("settings.ai.clear_memory") }
    public static var settingsAIClearHistory: String { tr("settings.ai.clear_history") }
    public static var settingsAIClearConfirm: String { tr("settings.ai.clear_confirm") }
    public static var settingsAIStatusReady: String { tr("settings.ai.status.ready") }
    public static var settingsAIStatusNotConfigured: String { tr("settings.ai.status.not_configured") }
    public static var settingsAIStatusConnecting: String { tr("settings.ai.status.connecting") }
    public static var settingsAIStatusError: String { tr("settings.ai.status.error") }
    public static var settingsNotifications: String { tr("settings.notifications") }
    public static var settingsNotificationsSystem: String { tr("settings.notifications.system") }
    public static var settingsNotificationsSystemDesc: String { tr("settings.notifications.system_desc") }
    public static var settingsNotificationsCalendar: String { tr("settings.notifications.calendar") }
    public static var settingsNotificationsCalendarDesc: String { tr("settings.notifications.calendar_desc") }
    public static var settingsNotificationsGithub: String { tr("settings.notifications.github") }
    public static var settingsNotificationsGithubToken: String { tr("settings.notifications.github_token") }
    public static var settingsNotificationsGithubTokenPlaceholder: String { tr("settings.notifications.github_token_placeholder") }
    public static var settingsNotificationsWebhook: String { tr("settings.notifications.webhook") }
    public static var settingsNotificationsWebhookEnabled: String { tr("settings.notifications.webhook_enabled") }
    public static var settingsNotificationsWebhookPort: String { tr("settings.notifications.webhook_port") }
    public static var settingsNotificationsWebhookHint: String { tr("settings.notifications.webhook_hint") }
    public static var settingsPetManagement: String { tr("settings.pet_management") }
    public static var settingsPetManagementName: String { tr("settings.pet_management.name") }
    public static var settingsPetManagementAppearance: String { tr("settings.pet_management.appearance") }
    public static var settingsPetManagementSize: String { tr("settings.pet_management.size") }
    public static var settingsPetManagementGender: String { tr("settings.pet_management.gender") }
    public static var settingsPetManagementGenderMale: String { tr("settings.pet_management.gender_male") }
    public static var settingsPetManagementGenderFemale: String { tr("settings.pet_management.gender_female") }
    public static var settingsPetManagementGenderNeutral: String { tr("settings.pet_management.gender_neutral") }
    public static var settingsPetManagementAge: String { tr("settings.pet_management.age") }
    public static var settingsPetManagementAgePlaceholder: String { tr("settings.pet_management.age_placeholder") }
    public static var settingsPetManagementPersonality: String { tr("settings.pet_management.personality") }
    public static var settingsPetManagementPersonalityPlaceholder: String { tr("settings.pet_management.personality_placeholder") }
    public static var settingsPetManagementHobbies: String { tr("settings.pet_management.hobbies") }
    public static var settingsPetManagementHobbiesPlaceholder: String { tr("settings.pet_management.hobbies_placeholder") }
    public static var settingsPetManagementEdit: String { tr("settings.pet_management.edit") }
    public static var settingsPetManagementSave: String { tr("settings.pet_management.save") }
    public static var settingsPetManagementCancel: String { tr("settings.pet_management.cancel") }
    public static var settingsPetManagementDelete: String { tr("settings.pet_management.delete") }
    public static var settingsPetManagementDeleteConfirm: String { tr("settings.pet_management.delete_confirm") }
    public static var settingsPetManagementAdd: String { tr("settings.pet_management.add") }
    public static var settingsPetManagementMaxReached: String { tr("settings.pet_management.max_reached") }
    public static var settingsCurrentAppearance: String { tr("settings.current_appearance") }
    public static var settingsCapabilities: String { tr("settings.capabilities") }
    public static var settingsPlugins: String { tr("settings.plugins") }
    public static var settingsNoSpritePacks: String { tr("settings.no_sprite_packs") }
    public static var settingsNoPlugins: String { tr("settings.no_plugins") }
    public static var settingsTitle: String { tr("settings.title") }
    public static var capabilityScreenAwarenessName: String { tr("capability.screen_awareness.name") }
    public static var capabilityScreenAwarenessDescription: String { tr("capability.screen_awareness.description") }
    public static var capabilityCalendarAccessName: String { tr("capability.calendar_access.name") }
    public static var capabilityCalendarAccessDescription: String { tr("capability.calendar_access.description") }
    public static var capabilityFocusMonitoringName: String { tr("capability.focus_monitoring.name") }
    public static var capabilityFocusMonitoringDescription: String { tr("capability.focus_monitoring.description") }

    public static var activityLogTitle: String { tr("activity_log.title") }
    public static var activityLogRecent: String { tr("activity_log.recent") }
    public static var activityLogEmpty: String { tr("activity_log.empty") }
    public static var activityLogLoadMore: String { tr("activity_log.load_more") }
    public static var activityLogNoInfo: String { tr("activity_log.no_info") }

    public static var chatStatusNotConfigured: String { tr("chat.status.not_configured") }
    public static var chatInputPlaceholder: String { tr("chat.input.placeholder") }
    public static var chatPlaceholderAllPets: String { tr("chat.placeholder.all_pets") }
    public static var chatPlaceholderSelectedPets: String { tr("chat.placeholder.selected_pets") }
    public static var chatSelectPets: String { tr("chat.select_pets") }
    public static var chatStreamingPlaceholder: String { tr("chat.streaming_placeholder") }
    public static var chatSend: String { tr("chat.send") }
    public static var chatEmptyNotConfigured: String { tr("chat.empty.not_configured") }
    public static var chatEmptyNewConversation: String { tr("chat.empty.new_conversation") }
    public static var chatEmptyStart: String { tr("chat.empty.start") }
    public static var chatOpenSettings: String { tr("chat.open_settings") }
    public static var chatPromptSummarizeSchedule: String { tr("chat.prompt.summarize_schedule") }
    public static var chatPromptSummarizeScheduleText: String { tr("chat.prompt.summarize_schedule.text") }
    public static var chatPromptWriteStatus: String { tr("chat.prompt.write_status") }
    public static var chatPromptWriteStatusText: String { tr("chat.prompt.write_status.text") }
    public static var chatPromptChatWithPet: String { tr("chat.prompt.chat_with_pet") }
    public static var chatPromptChatWithPetText: String { tr("chat.prompt.chat_with_pet.text") }
    public static var chatSubtitleGroup: String { tr("chat.subtitle.group") }
    public static var chatSubtitleSingle: String { tr("chat.subtitle.single") }
    public static func chatSubtitleReplying(_ prefix: String) -> String {
        String(format: tr("chat.subtitle.replying"), prefix)
    }
    public static func chatSubtitleMessages(_ prefix: String, _ count: Int) -> String {
        String(format: tr("chat.subtitle.messages"), prefix, count)
    }
    public static var chatSidebarTagline: String { tr("chat.sidebar.tagline") }
    public static func chatSidebarConversationsCount(_ count: Int) -> String {
        String(format: tr("chat.sidebar.conversations_count"), count)
    }
    public static func chatSidebarGroupsCount(_ count: Int) -> String {
        String(format: tr("chat.sidebar.groups_count"), count)
    }
    public static var chatPreviewGroup: String { tr("chat.preview.group") }
    public static var chatPreviewSingle: String { tr("chat.preview.single") }
    public static var chatHelpHideThinking: String { tr("chat.help.hide_thinking") }
    public static var chatHelpShowThinking: String { tr("chat.help.show_thinking") }
    public static var chatHelpOpacity: String { tr("chat.help.opacity") }
    public static var chatThinking: String { tr("chat.thinking") }
    public static var chatCreateGroupHint: String { tr("chat.create_group_hint") }
    public static var chatAssistantNotConfigured: String { tr("chat.assistant.not_configured") }
    public static var chatGroupChatPrompt: String { tr("chat.group_chat_prompt") }
    public static var chatGroupChatPetsHeader: String { tr("chat.group_chat_pets_header") }
    public static var chatGroupChatExample: String { tr("chat.group_chat_example") }
    public static var chatSingleChat: String { tr("chat.single_chat") }
    public static var chatGroupChat: String { tr("chat.group_chat") }
    public static var chatConversations: String { tr("chat.conversations") }
    public static var chatNewGroup: String { tr("chat.new_group") }
    public static var chatCreateGroup: String { tr("chat.create_group") }
    public static var chatGroupName: String { tr("chat.group_name") }
    public static var chatGroupNamePlaceholder: String { tr("chat.group_name_placeholder") }
    public static var chatSelectMembers: String { tr("chat.select_members") }
    public static var chatNoConversation: String { tr("chat.no_conversation") }
    public static var chatDeleteConversation: String { tr("chat.delete_conversation") }
    public static var chatDeleteConversationConfirm: String { tr("chat.delete_conversation_confirm") }
    public static var aiProactiveGreeting: String { tr("ai.proactive.greeting") }
    public static var aiProactiveRestReminder: String { tr("ai.proactive.rest_reminder") }
    public static var aiMemoryExtracted: String { tr("ai.memory.extracted") }
    public static var settingsSpritePacksImport: String { tr("settings.sprite_packs.import") }
    public static var settingsSpritePacksCreateTemplate: String { tr("settings.sprite_packs.create_template") }
    public static var settingsSpritePacksExport: String { tr("settings.sprite_packs.export") }
    public static var settingsSpritePacksRevealFinder: String { tr("settings.sprite_packs.reveal_finder") }
    public static var settingsSpritePacksDelete: String { tr("settings.sprite_packs.delete") }
    public static var settingsSpritePacksDeleteConfirm: String { tr("settings.sprite_packs.delete_confirm") }
    public static var settingsSpritePacksStatesCount: String { tr("settings.sprite_packs.states_count") }
    public static var settingsSpritePacksFramesCount: String { tr("settings.sprite_packs.frames_count") }
    public static var settingsSpritePacksBuiltIn: String { tr("settings.sprite_packs.built_in") }
    public static var settingsSpritePacksImportError: String { tr("settings.sprite_packs.import_error") }
    public static var settingsSpritePacksDeleteError: String { tr("settings.sprite_packs.delete_error") }
    public static var settingsSpritePacksValidationMissingManifest: String { tr("settings.sprite_packs.validation_missing_manifest") }
    public static var settingsSpritePacksValidationMissingFrame: String { tr("settings.sprite_packs.validation_missing_frame") }
    public static var settingsSpritePacksValidationMissingIdle: String { tr("settings.sprite_packs.validation_missing_idle") }
    public static var settingsSpritePacksValidationInvalidManifest: String { tr("settings.sprite_packs.validation_invalid_manifest") }
    public static var spritePackCreatorTitle: String { tr("sprite_pack_creator.title") }
    public static var spritePackCreatorPackName: String { tr("sprite_pack_creator.pack_name") }
    public static var spritePackCreatorPackNamePlaceholder: String { tr("sprite_pack_creator.pack_name_placeholder") }
    public static var spritePackCreatorStateRequired: String { tr("sprite_pack_creator.state_required") }
    public static var spritePackCreatorAddFrames: String { tr("sprite_pack_creator.add_frames") }
    public static var spritePackCreatorImportFolder: String { tr("sprite_pack_creator.import_folder") }
    public static var spritePackCreatorBuild: String { tr("sprite_pack_creator.build") }
    public static var spritePackCreatorBuilding: String { tr("sprite_pack_creator.building") }
    public static var spritePackCreatorSuccess: String { tr("sprite_pack_creator.success") }
    public static var spritePackCreatorDropHint: String { tr("sprite_pack_creator.drop_hint") }
    public static var spritePackCreatorFramesCount: String { tr("sprite_pack_creator.frames_count") }
    public static var petInteractionGreet: [String] { trs("pet.interaction.greet") }
    public static var petInteractionChatA: [String] { trs("pet.interaction.chat_a") }
    public static var petInteractionChatB: [String] { trs("pet.interaction.chat_b") }
    public static var petInteractionChaseStart: String { tr("pet.interaction.chase_start") }
    public static var petInteractionChaseCaught: String { tr("pet.interaction.chase_caught") }
    public static var petInteractionDance: String { tr("pet.interaction.dance") }

    public static var petContextFeed: String { tr("pet.context.feed") }
    public static var petContextPlay: String { tr("pet.context.play") }
    public static var petContextPat: String { tr("pet.context.pat") }
    public static var petHoverTexts: [String] { trs("pet.hover") }
    public static var petDragLongTexts: [String] { trs("pet.drag.long") }
    public static var petDragThrowTexts: [String] { trs("pet.drag.throw") }
    public static var petAmbientHappy: [String] { trs("pet.ambient.happy") }
    public static var petAmbientNormal: [String] { trs("pet.ambient.normal") }
    public static var petAmbientSad: [String] { trs("pet.ambient.sad") }

    public static func tr(_ key: String) -> String {
        guard let value = storage.value(for: key, locale: locale) as? String else {
            return key
        }

        return value
    }

    public static func trs(_ key: String) -> [String] {
        guard let value = storage.value(for: key, locale: locale) as? [String] else {
            return [key]
        }

        return value
    }

    private static let storage = Storage()
}

private final class Storage: @unchecked Sendable {
    private static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(
            forResource: "VitaPet_Localization",
            withExtension: "bundle"
        ), let packagedBundle = Bundle(url: url) {
            return packagedBundle
        }
        return Bundle.module
    }()

    private let lock = NSLock()
    private var currentLocale = "zh-Hans"
    private var cachedTables: [String: [String: Any]] = [:]

    var locale: String {
        get {
            lock.withLock { currentLocale }
        }
        set {
            lock.withLock { currentLocale = newValue }
        }
    }

    func value(for key: String, locale: String) -> Any? {
        table(for: locale)[key]
    }

    private func table(for locale: String) -> [String: Any] {
        lock.lock()
        if let cached = cachedTables[locale] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let loaded = loadTable(for: locale) ?? loadTable(for: "zh-Hans") ?? [:]

        lock.lock()
        cachedTables[locale] = loaded
        lock.unlock()
        return loaded
    }

    private func loadTable(for locale: String) -> [String: Any]? {
        guard let url = LocalizationResourceLookup.tableURL(for: locale, in: Self.resourceBundle),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        return dictionary
    }
}

enum LocalizationResourceLookup {
    static func tableURL(for locale: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: locale, withExtension: "json", subdirectory: "Resources")
            ?? bundle.url(forResource: locale, withExtension: "json")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
