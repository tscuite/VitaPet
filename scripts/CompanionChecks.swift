import Foundation
import RenderEngine

@main
struct CompanionChecks {
    @MainActor
    static func main() throws {
        func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
            precondition(value, file: file, line: line)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 30, hour: 12))!
        var progress = CompanionProgress(now: start)
        precondition(progress.isValid && progress.level == 1 && progress.currentStreak(at: start) == 0)
        precondition(progress.journal.isEmpty && progress.actionsToday(at: start).isEmpty)
        precondition(progress.needs(at: start.addingTimeInterval(-3600)).fullness == 70)

        // Daily reward, cooldown and repeat-click farming.
        for action in CareAction.allCases { try progress.perform(action, at: start, calendar: calendar) }
        precondition(progress.experience == 60 && progress.totalCareCount == 4 && progress.streak == 1)
        precondition(progress.badges == [.firstCare, .dailyRoutine])
        let before = progress
        do {
            try progress.perform(.feed, at: start.addingTimeInterval(30), calendar: calendar)
            preconditionFailure("Cooldown should reject repeated care")
        } catch CareError.cooldown(let seconds) {
            precondition(seconds == 30 && progress == before)
        }
        check(try progress.perform(.feed, at: start.addingTimeInterval(60), calendar: calendar) == 0)
        precondition(progress.experience == 60)

        // Calendar-day boundaries (not rolling 24-hour windows), month boundaries and broken streaks.
        for offset in 1...2 {
            let next = calendar.date(byAdding: .day, value: offset, to: start)!
            precondition(progress.actionsToday(at: next, calendar: calendar).isEmpty)
            try progress.perform(.pat, at: next, calendar: calendar)
        }
        precondition(progress.streak == 3 && progress.badges.contains(.threeDays))
        let later = calendar.date(byAdding: .day, value: 5, to: start)!
        precondition(progress.currentStreak(at: later, calendar: calendar) == 0)
        try progress.perform(.pat, at: later, calendar: calendar)
        precondition(progress.streak == 1 && progress.bestStreak == 3 && progress.badges.contains(.threeDays))
        let beforeRollback = progress
        do {
            try progress.perform(.pat, at: start, calendar: calendar)
            preconditionFailure("Clock rollback must not bypass cooldown")
        } catch CareError.cooldown {
            precondition(progress == beforeRollback)
        }

        // Needs keep fractional decay even when the user interacts every minute.
        var frequent = CompanionProgress(now: start)
        for minute in 0...60 {
            try frequent.perform(.pat, at: start.addingTimeInterval(Double(minute * 60)), calendar: calendar)
        }
        precondition(frequent.needs(at: start.addingTimeInterval(3600)).fullness == 67)
        precondition(frequent.needs(at: start.addingTimeInterval(3600)).energy == 73)
        precondition(frequent.journal.count == 60 && frequent.experience == 10)
        for minute in 61...100 {
            try frequent.perform(.pat, at: start.addingTimeInterval(Double(minute * 60)), calendar: calendar)
        }
        precondition(frequent.badges.contains(.devoted) && frequent.isValid)

        // Returning after a long absence never loses levels. Rest makes play possible again.
        let longAbsence = start.addingTimeInterval(365 * 86400)
        precondition(progress.needs(at: longAbsence).fullness == 20)
        precondition(progress.needs(at: longAbsence).energy == 20)
        let tired = progress
        do {
            try progress.perform(.play, at: longAbsence, calendar: calendar)
            preconditionFailure("Low energy should suggest rest")
        } catch CareError.needsRest {
            precondition(progress == tired)
        }
        try progress.perform(.rest, at: longAbsence, calendar: calendar)
        try progress.perform(.play, at: longAbsence, calendar: calendar)
        precondition(progress.experience > tired.experience && progress.isValid)

        // Daily bonuses, level rollover and the level-five badge.
        var growing = CompanionProgress(now: start)
        for day in 0...6 {
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            for action in [CareAction.rest, .feed, .play, .pat] {
                try growing.perform(action, at: date, calendar: calendar)
            }
        }
        precondition(growing.experience == 420 && growing.level == 5 && growing.levelExperience == 20)
        precondition(growing.badges.contains(.bestFriends) && growing.streak == 7)
        let restored = try JSONDecoder().decode(CompanionProgress.self, from: JSONEncoder().encode(growing))
        precondition(restored == growing && restored.isValid)

        // Spring DST is a 23-hour day, but still advances the streak by exactly one.
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = pacific.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let springNext = pacific.date(byAdding: .day, value: 1, to: spring)!
        precondition(springNext.timeIntervalSince(spring) == 23 * 3600)
        var dst = CompanionProgress(now: spring)
        try dst.perform(.pat, at: spring, calendar: pacific)
        try dst.perform(.pat, at: springNext, calendar: pacific)
        precondition(dst.streak == 2 && dst.experience == 20)
        precondition(dst.actionsToday(at: springNext, calendar: calendar).isEmpty == false)

        // Actual storage implementation: per-pet isolation, restart persistence and damaged-file safety.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VitaPetCareChecks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionStore(directory: root)
        let cat = UUID(), dog = UUID()
        check(try store.progress(for: cat, at: start).experience == 0)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("companion.json").path))
        try store.perform(.feed, for: cat, at: start)
        check(try store.progress(for: dog, at: start).experience == 0)
        let reopened = CompanionStore(directory: root)
        check(try reopened.progress(for: cat, at: start).experience == 10)
        check(try reopened.progress(for: cat, at: start).cooldown(for: .feed, at: start) == 60)

        let file = root.appendingPathComponent("companion.json")
        let validData = try Data(contentsOf: file)
        try Data("broken save".utf8).write(to: file)
        let damaged = CompanionStore(directory: root)
        do {
            try damaged.perform(.pat, for: cat, at: start)
            preconditionFailure("Damaged saves must not be overwritten")
        } catch {
            check(try Data(contentsOf: file) == Data("broken save".utf8))
        }
        // Fixing the file should allow the same store to retry.
        try validData.write(to: file)
        check(try damaged.progress(for: cat, at: start).experience == 10)

        var object = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        object["version"] = 999
        let futureData = try JSONSerialization.data(withJSONObject: object)
        try futureData.write(to: file)
        do {
            try CompanionStore(directory: root).perform(.pat, for: cat, at: start)
            preconditionFailure("Future save versions must be preserved")
        } catch CompanionStore.StoreError.invalidSave {
            check(try Data(contentsOf: file) == futureData)
        }

        // Failed atomic writes don't consume cooldown or award XP in memory.
        try validData.write(to: file)
        let failing = CompanionStore(directory: root)
        let original = try failing.progress(for: cat, at: start)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        do {
            try failing.perform(.pat, for: cat, at: start)
            preconditionFailure("Writing over a directory must fail")
        } catch {
            check(try failing.progress(for: cat, at: start) == original)
        }
        try FileManager.default.removeItem(at: file)
        try failing.perform(.pat, for: cat, at: start)
        check(try failing.progress(for: cat, at: start).experience == 20)

        var renderPolicy = SpritePackPreviewRenderPolicy()
        precondition(renderPolicy.shouldRender(.init(packDirectory: nil, previewSize: 64)))
        precondition(!renderPolicy.shouldRender(.init(packDirectory: nil, previewSize: 64)))
        precondition(renderPolicy.shouldRender(.init(packDirectory: nil, previewSize: 64, reduceMotion: true)))
        precondition(!renderPolicy.shouldRender(.init(packDirectory: nil, previewSize: 64, reduceMotion: true)))

        print("PASS: daily XP, cooldown, streaks, DST, clock rollback, needs, badges, journal, persistence, isolation, write-failure recovery and reduced-motion render policy")
    }
}
