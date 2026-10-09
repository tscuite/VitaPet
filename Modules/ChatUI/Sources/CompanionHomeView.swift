import AppKit
import Localization
import RenderEngine
import SwiftUI

public struct CompanionPet: Identifiable {
    public let id: UUID
    public let name: String
    public let packDirectory: URL?
    public let happiness: Int
    public let progress: CompanionProgress

    public init(id: UUID, name: String, packDirectory: URL?, happiness: Int, progress: CompanionProgress) {
        self.id = id
        self.name = name
        self.packDirectory = packDirectory
        self.happiness = happiness
        self.progress = progress
    }
}

public struct CompanionFocusState {
    public let status: String
    public let isIdle: Bool
    public let isPaused: Bool
    public let remaining: Int
    public let duration: Int

    public init(status: String, isIdle: Bool, isPaused: Bool, remaining: Int, duration: Int) {
        self.status = status
        self.isIdle = isIdle
        self.isPaused = isPaused
        self.remaining = remaining
        self.duration = duration
    }
}

/// Uses the existing pet previews, games and focus controller, rather than a second simulation.
@MainActor
public struct CompanionHomeView: View {
    let loadPets: @MainActor () throws -> [CompanionPet]
    let onCare: @MainActor (UUID, CareAction) async throws -> String
    let onChat: @MainActor (UUID) -> Void
    let focusState: @MainActor () -> CompanionFocusState
    let onToggleFocus: @MainActor () -> Void
    let onResetFocus: @MainActor () -> Void
    let availableGames: @MainActor () -> [String]
    let onStartGame: @MainActor (String) -> Void
    @State private var pets: [CompanionPet] = []
    @State private var selectedPetID: UUID?
    @State private var feedback: String?
    @State private var actionFailed = false
    @State private var loadError: String?
    @State private var isCaring = false
    @State private var showAllJournal = false

    public init(
        selectedPetID: UUID? = nil,
        loadPets: @escaping @MainActor () throws -> [CompanionPet],
        onCare: @escaping @MainActor (UUID, CareAction) async throws -> String,
        onChat: @escaping @MainActor (UUID) -> Void,
        focusState: @escaping @MainActor () -> CompanionFocusState,
        onToggleFocus: @escaping @MainActor () -> Void,
        onResetFocus: @escaping @MainActor () -> Void,
        availableGames: @escaping @MainActor () -> [String],
        onStartGame: @escaping @MainActor (String) -> Void
    ) {
        _selectedPetID = State(initialValue: selectedPetID)
        self.loadPets = loadPets
        self.onCare = onCare
        self.onChat = onChat
        self.focusState = focusState
        self.onToggleFocus = onToggleFocus
        self.onResetFocus = onResetFocus
        self.availableGames = availableGames
        self.onStartGame = onStartGame
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button(L10n.tr("home.retry"), action: reload)
                }
                if let pet = pets.first(where: { $0.id == selectedPetID }) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 24) {
                            petSummary(pet, at: context.date)
                            careButtons(pet, at: context.date)
                            if let feedback {
                                Label(feedback, systemImage: actionFailed ? "exclamationmark.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(actionFailed ? Color.red : Color.primary)
                                    .font(.callout)
                                    .accessibilityIdentifier("home.feedback")
                            }
                            Divider()
                            HStack(alignment: .top, spacing: 32) {
                                dailyGoals(pet, at: context.date)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                focusPanel
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                            achievements(pet)
                            journal(pet)
                        }
                    }
                } else if loadError == nil {
                    ContentUnavailableView(L10n.tr("home.empty"), systemImage: "pawprint", description: Text(L10n.tr("home.empty_hint")))
                }
                Text(L10n.tr("home.local_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion.home")
        .task {
            reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                reload()
            }
        }
        .onChange(of: selectedPetID) { _, _ in feedback = nil }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("home.title"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(L10n.tr("home.subtitle"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pets.count > 1 {
                Picker(L10n.tr("home.pet"), selection: $selectedPetID) {
                    ForEach(pets) { pet in
                        Text(pet.name).tag(Optional(pet.id))
                    }
                }
                .frame(width: 180)
            }
        }
    }

    private func petSummary(_ pet: CompanionPet, at now: Date) -> some View {
        let needs = pet.progress.needs(at: now)
        return HStack(spacing: 28) {
            VStack(spacing: 4) {
                SpritePackPreviewView(packDirectory: pet.packDirectory, previewSize: 112)
                    .frame(width: 112, height: 112)
                    .accessibilityLabel(pet.name)
                Capsule().fill(Color.accentColor.opacity(0.15)).frame(width: 108, height: 8)
                Text(String(format: L10n.tr("home.streak"), pet.progress.currentStreak(at: now)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .frame(width: 150)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(pet.name).font(.system(size: 23, weight: .semibold, design: .rounded))
                    Text(String(format: L10n.tr("home.level"), pet.progress.level))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { onChat(pet.id) } label: { Label(L10n.menuChat, systemImage: "bubble.left") }
                }
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: Double(pet.progress.levelExperience), total: 100)
                        .tint(.accentColor)
                        .accessibilityLabel(L10n.tr("home.bond"))
                    Text(String(format: L10n.tr("home.experience"), pet.progress.levelExperience))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 22) {
                    needMeter("home.fullness", symbol: "carrot.fill", value: needs.fullness, color: .orange)
                    needMeter("home.energy", symbol: "bolt.fill", value: needs.energy, color: .teal)
                    needMeter("home.mood", symbol: "heart.fill", value: pet.happiness, color: .pink)
                }
            }
        }
    }

    private func needMeter(_ key: String, symbol: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(L10n.tr(key), systemImage: symbol).foregroundStyle(color)
                Spacer(minLength: 4)
                Text("\(value)").monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: Double(value), total: 100)
                .tint(color)
                .accessibilityLabel(L10n.tr(key))
                .accessibilityValue("\(value) / 100")
        }
    }

    private func careButtons(_ pet: CompanionPet, at now: Date) -> some View {
        HStack(spacing: 12) {
            ForEach(CareAction.allCases, id: \.self) { action in
                let cooldown = pet.progress.cooldown(for: action, at: now)
                let tired = action == .play && pet.progress.needs(at: now).energy < 30
                Button { perform(action, for: pet) } label: {
                    VStack(spacing: 7) {
                        Label(action.title, systemImage: action.symbol)
                            .font(.system(size: 14, weight: .semibold))
                        Text(cooldown > 0 ? String(format: L10n.tr("home.cooldown_short"), cooldown)
                             : tired ? L10n.tr("home.rest_first") : L10n.tr("home.action.\(action.rawValue).hint"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(cooldown > 0 || tired || loadError != nil || isCaring)
                .accessibilityIdentifier("home.care.\(action.rawValue)")
            }
        }
    }

    private func dailyGoals(_ pet: CompanionPet, at now: Date) -> some View {
        let completed = pet.progress.actionsToday(at: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("home.daily")).font(.headline)
                Spacer()
                Text("\(completed.count) / 4").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(CareAction.allCases, id: \.self) { action in
                HStack {
                    Image(systemName: completed.contains(action) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(completed.contains(action) ? Color.accentColor : Color.secondary)
                    Text(action.title)
                    Spacer()
                    Text(completed.contains(action) ? L10n.tr("home.done") : "+10 XP")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text(L10n.tr(completed.count == 4 ? "home.daily_complete" : "home.daily_hint"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var focusPanel: some View {
        let focus = focusState()
        let games = availableGames()
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("home.together")).font(.headline)
            Label(focus.status, systemImage: "timer").monospacedDigit()
            if !focus.isIdle {
                ProgressView(value: Double(max(0, focus.duration - focus.remaining)), total: Double(max(1, focus.duration)))
            }
            Text(L10n.tr("home.focus_hint")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(focus.isIdle ? L10n.menuPomodoroStart : focus.isPaused ? L10n.menuPomodoroResume : L10n.menuPomodoroPause, action: onToggleFocus)
                    .buttonStyle(.borderedProminent)
                if !focus.isIdle {
                    Button(L10n.menuPomodoroReset, action: onResetFocus)
                }
                Menu {
                    ForEach(games, id: \.self) { game in
                        Button(game) { onStartGame(game) }
                    }
                } label: {
                    Label(L10n.menuMiniGames, systemImage: "gamecontroller")
                }
                .disabled(games.isEmpty)
            }
        }
    }

    private func achievements(_ pet: CompanionPet) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("home.achievements")).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 16) {
                ForEach(CompanionBadge.allCases, id: \.self) { badge in
                    let unlocked = pet.progress.badges.contains(badge)
                    VStack(spacing: 8) {
                        Image(systemName: unlocked ? "rosette" : "lock.circle")
                            .font(.system(size: 24))
                            .foregroundStyle(unlocked ? Color.accentColor : Color.secondary)
                        Text(L10n.tr("home.badge.\(badge.rawValue)")).font(.callout.weight(.medium))
                        Text(L10n.tr("home.badge.\(badge.rawValue).hint"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.tr(unlocked ? "home.unlocked" : "home.locked"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 108)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func journal(_ pet: CompanionPet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("home.journal")).font(.headline)
            if pet.progress.journal.isEmpty {
                Label(L10n.tr("home.journal_empty"), systemImage: "book.closed")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(pet.progress.journal.prefix(showAllJournal ? 60 : 12)) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.action.symbol).frame(width: 20).foregroundStyle(.secondary)
                        Text(L10n.tr("home.entry.\(entry.action.rawValue)"))
                        if entry.experience > 0 {
                            Text("+\(entry.experience) XP").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.date, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if pet.progress.journal.count > 12 {
                    Button(L10n.tr(showAllJournal ? "home.journal_less" : "home.journal_more")) {
                        showAllJournal.toggle()
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func perform(_ action: CareAction, for pet: CompanionPet) {
        guard !isCaring else { return }
        isCaring = true
        Task { @MainActor in
            defer { isCaring = false }
            do {
                let response = try await onCare(pet.id, action)
                if selectedPetID == pet.id {
                    feedback = response
                    actionFailed = false
                }
                reload()
            } catch {
                if selectedPetID == pet.id {
                    feedback = error.localizedDescription
                    actionFailed = true
                }
            }
        }
    }

    private func reload() {
        do {
            pets = try loadPets()
            if !pets.contains(where: { $0.id == selectedPetID }) { selectedPetID = pets.first?.id }
            loadError = nil
        } catch {
            loadError = L10n.tr("home.load_error")
        }
    }
}

private extension CareAction {
    var title: String { L10n.tr("home.action.\(rawValue)") }
    var symbol: String {
        switch self {
        case .feed: return "carrot.fill"
        case .play: return "tennisball.fill"
        case .pat: return "hand.raised.fingers.spread.fill"
        case .rest: return "moon.zzz.fill"
        }
    }
}
