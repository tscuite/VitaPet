@testable import EventBus
import XCTest

private actor FileChangeRecorder {
    private var events: [(path: String, flags: UInt32)] = []

    func record(path: String, flags: UInt32) {
        events.append((path: path, flags: flags))
    }

    func matchingEvents(for path: String) -> [(path: String, flags: UInt32)] {
        events.filter {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path
        }
    }
}

final class FSEventsMonitorTests: XCTestCase {
    func testSourceId_isFsEvents() async {
        let source = FSEventsMonitor(paths: [NSTemporaryDirectory()])

        let sourceId = await source.sourceId

        XCTAssertEqual(sourceId, "fsEvents")
    }

    func testStart_publishesFileChangedEvent() async throws {
        let eventBus = EventBus()
        let directoryURL = try makeTemporaryDirectory()
        let source = FSEventsMonitor(paths: [directoryURL.path])
        let recorder = FileChangeRecorder()
        let changedFileURL = directoryURL.appendingPathComponent("created.txt")
        let expectedPath = changedFileURL.resolvingSymlinksInPath().path
        let eventReceived = expectation(description: "file changed event published")
        eventReceived.assertForOverFulfill = false

        defer {
            Task {
                await source.stop()
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        _ = await eventBus.subscribe { event in
            guard case let .fileChanged(path, flags) = event else {
                return
            }

            await recorder.record(path: path, flags: flags)
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expectedPath {
                XCTAssertNotEqual(flags, 0)
                eventReceived.fulfill()
            }
        }

        await source.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(300))
        try Data("hello".utf8).write(to: changedFileURL)

        await fulfillment(of: [eventReceived], timeout: 5.0)

        let matchingEvents = await recorder.matchingEvents(for: expectedPath)
        XCTAssertFalse(matchingEvents.isEmpty)
    }

    func testMultipleStart_isIdempotent() async throws {
        let eventBus = EventBus()
        let directoryURL = try makeTemporaryDirectory()
        let source = FSEventsMonitor(paths: [directoryURL.path])
        let recorder = FileChangeRecorder()
        let changedFileURL = directoryURL.appendingPathComponent("duplicate-check.txt")
        let expectedPath = changedFileURL.resolvingSymlinksInPath().path
        let eventReceived = expectation(description: "file changed event published")
        eventReceived.assertForOverFulfill = false

        defer {
            Task {
                await source.stop()
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        _ = await eventBus.subscribe { event in
            guard case let .fileChanged(path, flags) = event else {
                return
            }

            await recorder.record(path: path, flags: flags)
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expectedPath {
                eventReceived.fulfill()
            }
        }

        await source.start(publishingTo: eventBus)
        await source.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(300))
        try Data("hello".utf8).write(to: changedFileURL)

        await fulfillment(of: [eventReceived], timeout: 5.0)
        try? await Task.sleep(for: .milliseconds(500))
        await source.stop()

        let matchingEvents = await recorder.matchingEvents(for: expectedPath)
        XCTAssertLessThanOrEqual(matchingEvents.count, 3)
    }

    func testIsExcluded_matchesRootsAndPathComponents() {
        let roots = ["/Users/me/Library", "/Users/me/.Trash"]
        let components: Set<String> = ["node_modules", ".git"]

        XCTAssertTrue(FSEventsMonitor.isExcluded("/Users/me/Library/Caches/x", roots: roots, components: components))
        XCTAssertTrue(FSEventsMonitor.isExcluded("/Users/me/.Trash", roots: roots, components: components))
        XCTAssertTrue(FSEventsMonitor.isExcluded("/Users/me/proj/node_modules/a/b.js", roots: roots, components: components))
        XCTAssertTrue(FSEventsMonitor.isExcluded("/Users/me/proj/.git/index", roots: roots, components: components))

        XCTAssertFalse(FSEventsMonitor.isExcluded("/Users/me/LibraryNotes/a.txt", roots: roots, components: components))
        XCTAssertFalse(FSEventsMonitor.isExcluded("/Users/me/proj/src/node_modules.md", roots: roots, components: components))
        XCTAssertFalse(FSEventsMonitor.isExcluded("/Users/me/proj/src/main.swift", roots: roots, components: components))
        XCTAssertFalse(FSEventsMonitor.isExcluded("/Users/me/proj/node_modules/a.js", roots: roots, components: []))
    }

    func testDefaultExcludedPathComponents_coverCommonBuildAndCacheDirectories() {
        for name in ["node_modules", ".git", ".Trash", ".cache", "DerivedData", "__pycache__"] {
            XCTAssertTrue(FSEventsMonitor.defaultExcludedPathComponents.contains(name), name)
        }
    }

    func testStart_dropsEventsInsideExcludedPathComponents() async throws {
        let eventBus = EventBus()
        let directoryURL = try makeTemporaryDirectory()
        let ignoredDirectoryURL = directoryURL.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredDirectoryURL, withIntermediateDirectories: true)
        let source = FSEventsMonitor(paths: [directoryURL.path])
        let recorder = FileChangeRecorder()
        let ignoredFileURL = ignoredDirectoryURL.appendingPathComponent("ignored.txt")
        let ignoredPath = ignoredFileURL.resolvingSymlinksInPath().path
        let watchedFileURL = directoryURL.appendingPathComponent("watched.txt")
        let watchedPath = watchedFileURL.resolvingSymlinksInPath().path
        let watchedEventReceived = expectation(description: "watched file event published")
        watchedEventReceived.assertForOverFulfill = false

        defer {
            Task {
                await source.stop()
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        _ = await eventBus.subscribe { event in
            guard case let .fileChanged(path, flags) = event else {
                return
            }

            await recorder.record(path: path, flags: flags)
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path == watchedPath {
                watchedEventReceived.fulfill()
            }
        }

        await source.start(publishingTo: eventBus)
        try? await Task.sleep(for: .milliseconds(300))
        // Write the ignored file first: FSEvents delivers in order, so by the time the watched
        // event arrives the ignored one has either been dropped or already recorded.
        try Data("ignored".utf8).write(to: ignoredFileURL)
        try Data("watched".utf8).write(to: watchedFileURL)

        await fulfillment(of: [watchedEventReceived], timeout: 5.0)
        try? await Task.sleep(for: .milliseconds(300))

        let ignoredEvents = await recorder.matchingEvents(for: ignoredPath)
        XCTAssertTrue(ignoredEvents.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
