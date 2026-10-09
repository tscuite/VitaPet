import Foundation

public enum CareAction: String, Codable, CaseIterable, Sendable {
    case feed, play, pat, rest

    public var animation: String {
        switch self {
        case .feed: return "eat"
        case .play: return "play"
        case .pat: return "love"
        case .rest: return "nap"
        }
    }

    public var moodDelta: Int {
        switch self {
        case .feed: return 8
        case .play: return 5
        case .pat: return 3
        case .rest: return 2
        }
    }
}

public enum CareError: Error, Equatable {
    case cooldown(seconds: Int)
    case needsRest
}

public enum CompanionBadge: String, CaseIterable, Codable, Sendable {
    case firstCare, dailyRoutine, threeDays, bestFriends, devoted
}

public struct CareEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let action: CareAction
    public let experience: Int
}

/// Small, local-only growth record. Reading needs never writes or starts a timer.
public struct CompanionProgress: Codable, Equatable, Sendable {
    public private(set) var experience = 0
    public private(set) var totalCareCount = 0
    public private(set) var streak = 0
    public private(set) var bestStreak = 0
    public private(set) var lastCareDate: Date?
    public private(set) var dailyActions: Set<CareAction> = []
    public private(set) var badges: Set<CompanionBadge> = []
    public private(set) var journal: [CareEntry] = []
    private var lastActions: [String: Date] = [:]
    private var fullness: Double = 70
    private var energy: Double = 75
    private var updatedAt: Date

    public init(now: Date = Date()) {
        updatedAt = now
    }

    public var level: Int { 1 + experience / 100 }
    public var levelExperience: Int { experience % 100 }

    public func needs(at now: Date) -> (fullness: Int, energy: Int) {
        let needs = rawNeeds(at: now)
        return (Int(needs.fullness.rounded()), Int(needs.energy.rounded()))
    }

    private func rawNeeds(at now: Date) -> (fullness: Double, energy: Double) {
        let hours = max(0, now.timeIntervalSince(updatedAt)) / 3600
        // Absence is not punished: needs have a floor and growth is never lost.
        return (max(20, fullness - hours * 3), max(20, energy - hours * 2))
    }

    public func actionsToday(at now: Date, calendar: Calendar = .current) -> Set<CareAction> {
        guard let lastCareDate, calendar.isDate(lastCareDate, inSameDayAs: now) else { return [] }
        return dailyActions
    }

    public func currentStreak(at now: Date, calendar: Calendar = .current) -> Int {
        guard let lastCareDate else { return 0 }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: lastCareDate), to: calendar.startOfDay(for: now)
        ).day ?? 0
        return days <= 1 ? streak : 0
    }

    public func cooldown(for action: CareAction, at now: Date) -> Int {
        guard let last = lastActions[action.rawValue] else { return 0 }
        return Int(min(60, max(0, 60 - now.timeIntervalSince(last))).rounded(.up))
    }

    /// Each action earns 10 XP once per local calendar day; all four add a 20 XP bonus.
    /// Further care still changes needs, but cannot farm levels by repeatedly clicking.
    @discardableResult
    public mutating func perform(
        _ action: CareAction, at now: Date = Date(), calendar: Calendar = .current
    ) throws -> Int {
        let remaining = cooldown(for: action, at: now)
        guard remaining == 0 else { throw CareError.cooldown(seconds: remaining) }
        let current = rawNeeds(at: now)
        guard action != .play || current.energy.rounded() >= 30 else { throw CareError.needsRest }

        // Keep the reward day monotonic if the system clock moves backwards.
        let rewardDate = max(now, lastCareDate ?? now)
        let previousDay = lastCareDate.map { calendar.startOfDay(for: $0) }
        let today = calendar.startOfDay(for: rewardDate)
        if previousDay != today {
            let gap = previousDay.flatMap { calendar.dateComponents([.day], from: $0, to: today).day }
            streak = gap == 1 ? streak + 1 : 1
            bestStreak = max(bestStreak, streak)
            dailyActions.removeAll()
        }

        fullness = current.fullness
        energy = current.energy
        switch action {
        case .feed:
            fullness = min(100, fullness + 30)
            energy = min(100, energy + 5)
        case .play:
            fullness = max(20, fullness - 6)
            energy = max(20, energy - 12)
        case .pat:
            break
        case .rest:
            energy = min(100, energy + 30)
        }
        updatedAt = max(updatedAt, now)
        lastActions[action.rawValue] = now
        lastCareDate = rewardDate
        totalCareCount += 1
        let firstToday = dailyActions.insert(action).inserted
        let dailyBonus = firstToday && dailyActions.count == CareAction.allCases.count
        let earned = (firstToday ? 10 : 0) + (dailyBonus ? 20 : 0)
        experience += earned

        badges.insert(.firstCare)
        if dailyBonus { badges.insert(.dailyRoutine) }
        if bestStreak >= 3 { badges.insert(.threeDays) }
        if level >= 5 { badges.insert(.bestFriends) }
        if totalCareCount >= 100 { badges.insert(.devoted) }
        journal.insert(CareEntry(id: UUID(), date: now, action: action, experience: earned), at: 0)
        journal = Array(journal.prefix(60))
        return earned
    }

    /// Reject damaged save files rather than silently replacing a user's progress.
    public var isValid: Bool {
        experience >= 0 && experience <= 100_000_000 && totalCareCount >= 0
            && totalCareCount <= 100_000_000 && streak >= 0 && bestStreak >= streak
            && bestStreak <= totalCareCount && fullness.isFinite && energy.isFinite
            && (20...100).contains(fullness) && (20...100).contains(energy)
            && updatedAt.timeIntervalSince1970.isFinite
            && (lastCareDate?.timeIntervalSince1970.isFinite ?? true)
            && lastActions.values.allSatisfy { $0.timeIntervalSince1970.isFinite }
            && journal.count <= 60
            && journal.allSatisfy { (0...30).contains($0.experience) && $0.date.timeIntervalSince1970.isFinite }
    }
}
