import Foundation

public struct SpritePackInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let directory: URL

    public init(id: String, name: String, directory: URL) {
        self.id = id
        self.name = name
        self.directory = directory
    }
}

public struct SpritePackLoader: Sendable {
    /// 内置精灵包 ID 列表（不含 "default"，default 已被 PixelCat 替代）
    public static let builtInPackIDs: Set<String> = ["PixelCat", "PixelDog", "PixelFox"]

    public static func loadManifest(from directory: URL) throws -> SpriteManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(SpriteManifest.self, from: data)
    }

    public static func loadBehaviorManifest(from directory: URL) -> BehaviorManifest? {
        let manifestURL = directory.appendingPathComponent("behavior.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(BehaviorManifest.self, from: data)
    }

    public static func discoverPacks() -> [SpritePackInfo] {
        discoverPacks(
            in: spritePacksDirectory(),
            bundledDirectory: bundledResourcesDirectory()
        )
    }

    /// Load the bundled default manifest from SPM resources
    public static func loadBundledManifest() -> SpriteManifest {
        let resourceBundle = RenderEngineResourceBundle.current
        if let url = resourceBundle.url(forResource: "manifest", withExtension: "json", subdirectory: "Resources") ??
                      resourceBundle.url(forResource: "manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(SpriteManifest.self, from: data) {
            return manifest
        }
        return defaultManifest()
    }

    public static func loadBundledBehaviorManifest() -> BehaviorManifest {
        let resourceBundle = RenderEngineResourceBundle.current
        if let url = resourceBundle.url(forResource: "behavior", withExtension: "json", subdirectory: "Resources") ??
                      resourceBundle.url(forResource: "behavior", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(BehaviorManifest.self, from: data) {
            return manifest
        }
        return BehaviorManifest.defaultManifest()
    }

    public static func defaultManifest() -> SpriteManifest {
        let states = AnimationState.allCases.reduce(into: [String: SpriteManifest.StateAnimation]()) {
            result,
            state in
            result[state.rawValue] = defaultAnimation(for: state)
        }

        return SpriteManifest(
            name: "DefaultSpritePack",
            version: "1.0.0",
            states: states
        )
    }

    static func discoverPacks(in spritePacksDirectory: URL, bundledDirectory: URL) -> [SpritePackInfo] {
        var discoveredPacks: [SpritePackInfo] = []

        let fileManager = FileManager.default
        if let candidateDirectories = try? fileManager.contentsOfDirectory(
            at: spritePacksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let packs = candidateDirectories.compactMap { directory -> SpritePackInfo? in
                guard
                    let resourceValues = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                    resourceValues.isDirectory == true,
                    let manifest = try? loadManifest(from: directory)
                else {
                    return nil
                }

                return SpritePackInfo(
                    id: directory.lastPathComponent,
                    name: manifest.name,
                    directory: directory
                )
            }

            // 内置包排前面，自定义包按名称排序
            let builtIn = packs.filter { builtInPackIDs.contains($0.id) }
                .sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            let custom = packs.filter { !builtInPackIDs.contains($0.id) }
                .sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            discoveredPacks = builtIn + custom
        }

        // 如果没发现任何包，fallback 到 bundled
        if discoveredPacks.isEmpty {
            discoveredPacks.append(
                SpritePackInfo(
                    id: "default",
                    name: loadBundledManifest().name,
                    directory: bundledDirectory
                )
            )
        }

        return discoveredPacks
    }

    static func defaultAnimation(for state: AnimationState) -> SpriteManifest.StateAnimation {
        let loopingStates: Set<AnimationState> = [
            .idle,
            .walk,
            .run,
            .follow,
            .sleep,
            .sit,
            .dance,
            .type,
            .read,
            .write,
            .phone,
            .nap,
            .meditate,
            .tailWag,
            .guardDuty
        ]

        switch state {
        case .idle:
            return .init(
                frames: ["pet_idle_0", "pet_idle_1"],
                frameInterval: 1.0 / 12.0,
                loop: true
            )
        case .walk:
            return .init(
                frames: ["pet_walk_0", "pet_walk_1", "pet_walk_2", "pet_walk_3"],
                frameInterval: 1.0 / 12.0,
                loop: true
            )
        case .react:
            return .init(
                frames: ["pet_react_0", "pet_react_1"],
                frameInterval: 1.0 / 12.0,
                loop: false
            )
        case .sleep:
            return .init(
                frames: ["pet_sleep_0", "pet_sleep_1"],
                frameInterval: 2.0 / 12.0,
                loop: true
            )
        case .drag:
            return .init(
                frames: ["pet_drag_0"],
                frameInterval: 1.0 / 12.0,
                loop: false
            )
        case .celebrate:
            return .init(
                frames: ["pet_celebrate_0", "pet_celebrate_1", "pet_celebrate_2"],
                frameInterval: 1.0 / 12.0,
                loop: false
            )
        case .stretch:
            return .init(
                frames: ["pet_react_1", "pet_react_0"],
                frameInterval: 0.4,
                loop: false
            )
        case .yawn:
            return .init(
                frames: ["pet_sleep_0", "pet_sleep_1"],
                frameInterval: 0.6,
                loop: false
            )
        case .lookAround:
            return .init(
                frames: ["pet_walk_0", "pet_walk_1"],
                frameInterval: 0.35,
                loop: false
            )
        case .bounce:
            return .init(
                frames: ["pet_celebrate_0", "pet_celebrate_1", "pet_celebrate_2"],
                frameInterval: 0.15,
                loop: false
            )
        case .punch:
            return .init(
                frames: ["pet_angry_0"],
                frameInterval: 0.14,
                loop: false
            )
        case .blink:
            return .init(frames: ["pet_blink_0", "pet_blink_1", "pet_blink_2", "pet_blink_3"], frameInterval: 0.09, loop: false)
        case .sniff:
            return .init(frames: ["pet_sniff_0", "pet_sniff_1", "pet_sniff_2", "pet_sniff_3"], frameInterval: 0.14, loop: false)
        case .tailWag:
            return .init(frames: ["pet_tailWag_0", "pet_tailWag_1", "pet_tailWag_2", "pet_tailWag_3", "pet_tailWag_4"], frameInterval: 0.10, loop: true)
        case .pawTap:
            return .init(frames: ["pet_pawTap_0", "pet_pawTap_1", "pet_pawTap_2", "pet_pawTap_3"], frameInterval: 0.10, loop: false)
        case .pounce:
            return .init(frames: ["pet_pounce_0", "pet_pounce_1", "pet_pounce_2", "pet_pounce_3"], frameInterval: 0.10, loop: false)
        case .crouch:
            return .init(frames: ["pet_crouch_0", "pet_crouch_1", "pet_crouch_2"], frameInterval: 0.14, loop: false)
        case .crawl:
            return .init(frames: ["pet_crawl_0", "pet_crawl_1", "pet_crawl_2", "pet_crawl_3"], frameInterval: 0.12, loop: false)
        case .nap:
            return .init(frames: ["pet_nap_0", "pet_nap_1", "pet_nap_2", "pet_nap_3"], frameInterval: 0.55, loop: true)
        case .dream:
            return .init(frames: ["pet_dream_0", "pet_dream_1", "pet_dream_2", "pet_dream_3"], frameInterval: 0.32, loop: false)
        case .beg:
            return .init(frames: ["pet_beg_0", "pet_beg_1", "pet_beg_2", "pet_beg_3"], frameInterval: 0.14, loop: false)
        case .nuzzle:
            return .init(frames: ["pet_nuzzle_0", "pet_nuzzle_1", "pet_nuzzle_2", "pet_nuzzle_3"], frameInterval: 0.14, loop: false)
        case .surprised:
            return .init(frames: ["pet_surprised_0", "pet_surprised_1", "pet_surprised_2"], frameInterval: 0.12, loop: false)
        case .blush:
            return .init(frames: ["pet_blush_0", "pet_blush_1", "pet_blush_2", "pet_blush_3"], frameInterval: 0.18, loop: false)
        case .proud:
            return .init(frames: ["pet_proud_0", "pet_proud_1", "pet_proud_2", "pet_proud_3"], frameInterval: 0.16, loop: false)
        case .melt:
            return .init(frames: ["pet_melt_0", "pet_melt_1", "pet_melt_2", "pet_melt_3"], frameInterval: 0.18, loop: false)
        case .sing:
            return .init(frames: ["pet_sing_0", "pet_sing_1", "pet_sing_2", "pet_sing_3", "pet_sing_4"], frameInterval: 0.13, loop: false)
        case .meditate:
            return .init(frames: ["pet_meditate_0", "pet_meditate_1", "pet_meditate_2", "pet_meditate_3"], frameInterval: 0.42, loop: true)
        case .coffee:
            return .init(frames: ["pet_coffee_0", "pet_coffee_1", "pet_coffee_2", "pet_coffee_3"], frameInterval: 0.22, loop: false)
        case .snack:
            return .init(frames: ["pet_snack_0", "pet_snack_1", "pet_snack_2", "pet_snack_3"], frameInterval: 0.15, loop: false)
        case .stargaze:
            return .init(frames: ["pet_stargaze_0", "pet_stargaze_1", "pet_stargaze_2", "pet_stargaze_3"], frameInterval: 0.28, loop: false)
        case .sparkle:
            return .init(frames: ["pet_sparkle_0", "pet_sparkle_1", "pet_sparkle_2", "pet_sparkle_3", "pet_sparkle_4"], frameInterval: 0.10, loop: false)
        case .slide:
            return .init(frames: ["pet_slide_0", "pet_slide_1", "pet_slide_2", "pet_slide_3"], frameInterval: 0.09, loop: false)
        case .pawReach:
            return .init(frames: ["pet_pawReach_0", "pet_pawReach_1", "pet_pawReach_2", "pet_pawReach_3"], frameInterval: 0.12, loop: false)
        case .guardDuty:
            return .init(frames: ["pet_guard_0", "pet_guard_1", "pet_guard_2", "pet_guard_3"], frameInterval: 0.22, loop: true)
        case .somersault:
            return .init(frames: ["pet_somersault_0", "pet_somersault_1", "pet_somersault_2", "pet_somersault_3"], frameInterval: 0.09, loop: false)
        case .danceCombo, .somersaultCombo, .boxingCombo, .parkourCombo, .partyCombo, .trainingCombo, .joySpinCombo:
            return .init(
                frames: ActionComboPlanner.manifestFrames(for: state, prefix: "pet") ?? ["pet_idle_0"],
                frameInterval: 0.12,
                loop: false
            )
        default:
            let frameCount = loopingStates.contains(state) || state == .run ? 4 : 3
            let frames = (0..<frameCount).map { "pet_\(state.rawValue)_\($0)" }
            let frameInterval: Double

            switch state {
            case .run:
                frameInterval = 0.08
            case .follow:
                frameInterval = 0.12
            case .eat, .drink:
                frameInterval = 0.35
            case .sit:
                frameInterval = 0.5
            case .think:
                frameInterval = 0.3
            case .chat, .wave, .cheer, .alert, .pickup, .land, .trip, .spin, .love, .dance, .play, .roll, .climb, .angry, .scared, .sneeze, .punch:
                frameInterval = 0.15
            case .sad, .shy, .confused, .peek, .gift, .read, .write, .phone, .listen, .hidePeek, .type, .groom, .nod, .headShake, .scratch:
                frameInterval = 0.2
            default:
                frameInterval = 1.0 / 12.0
            }

            return .init(
                frames: frames,
                frameInterval: frameInterval,
                loop: loopingStates.contains(state)
            )
        }
    }

    public static func spritePacksDirectory() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupportURL
            .appendingPathComponent("VitaPet", isDirectory: true)
            .appendingPathComponent("SpritePacks", isDirectory: true)
    }

    public static func bundledSpritePacksDirectory() -> URL? {
        let fileManager = FileManager.default
        let resourceURL = RenderEngineResourceBundle.current.resourceURL
        let directURL = resourceURL?.appendingPathComponent("SpritePacks", isDirectory: true)
        if let directURL, fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        let nestedURL = resourceURL?
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("SpritePacks", isDirectory: true)
        if let nestedURL, fileManager.fileExists(atPath: nestedURL.path) {
            return nestedURL
        }

        return nil
    }

    public static func bundledSpritePackDirectory(named name: String) -> URL? {
        guard let spritePacksDirectory = bundledSpritePacksDirectory() else {
            return nil
        }

        let packDirectory = spritePacksDirectory.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: packDirectory.path) else {
            return nil
        }

        return packDirectory
    }

    private static func bundledResourcesDirectory() -> URL {
        let bundleResourceURL = RenderEngineResourceBundle.current.resourceURL
        if let resourceURL = bundleResourceURL?.appendingPathComponent("Resources", isDirectory: true),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        return bundleResourceURL ?? spritePacksDirectory()
    }
}
