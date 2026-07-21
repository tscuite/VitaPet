import Persistence
import XCTest

final class EventPersistencePolicyTests: XCTestCase {
    func testHotkeyEventsAreTransient() {
        XCTAssertEqual(
            EventPersistencePolicy.strategy(forSource: "hotkeyPressed"),
            .transient
        )
    }

    func testFileChangesKeepBufferedPersistence() {
        XCTAssertEqual(
            EventPersistencePolicy.strategy(forSource: "fileChanged"),
            .bufferedFileChange
        )
    }

    func testOrdinaryEventsKeepImmediatePersistence() {
        XCTAssertEqual(
            EventPersistencePolicy.strategy(forSource: "notificationReceived"),
            .immediate
        )
    }

    func testRawHotkeyBurstCreatesNoPersistenceWork() {
        let persistentDecisionCount = (0..<10_000).reduce(into: 0) { count, _ in
            if EventPersistencePolicy.strategy(forSource: "hotkeyPressed") != .transient {
                count += 1
            }
        }

        XCTAssertEqual(persistentDecisionCount, 0)
    }
}
