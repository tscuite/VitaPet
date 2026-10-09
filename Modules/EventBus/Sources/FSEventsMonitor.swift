import CoreServices
import Foundation

public actor FSEventsMonitor: EventSource {
    public let sourceId: String

    /// Directory names that are pure build/cache noise for a desktop pet and would otherwise
    /// dominate the event stream (hundreds of thousands of rows per day when watching `$HOME`).
    public static let defaultExcludedPathComponents: Set<String> = [
        "node_modules", "target", "build", "dist", ".build", "DerivedData", "Pods",
        "venv", ".venv", "__pycache__", ".git", ".Trash", ".cache", ".npm", ".gradle",
        ".local", ".cargo", ".rustup", ".pyenv", ".rbenv", ".m2", ".docker", ".kube",
    ]

    private final class CallbackContext: @unchecked Sendable {
        let eventBus: EventBus
        let excludedRoots: [String]
        let excludedPathComponents: Set<String>
        let publicationTracker = EventPublicationTracker()

        init(eventBus: EventBus, excludedRoots: [String], excludedPathComponents: Set<String>) {
            self.eventBus = eventBus
            self.excludedRoots = excludedRoots
            self.excludedPathComponents = excludedPathComponents
        }
    }

    private let paths: [String]
    private let excludedRoots: [String]
    private let excludedPathComponents: Set<String>
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private var streamRef: FSEventStreamRef?
    private var callbackContext: UnsafeMutableRawPointer?

    private static let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
        guard let clientCallBackInfo else {
            return
        }

        let context = Unmanaged<CallbackContext>
            .fromOpaque(clientCallBackInfo)
            .takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: CFArray.self) as NSArray
        let eventBus = context.eventBus
        var acceptedEvents: [AppEvent] = []
        acceptedEvents.reserveCapacity(numEvents)

        for index in 0..<numEvents {
            guard let changedPath = paths[index] as? String else {
                continue
            }
            let normalizedPath = URL(fileURLWithPath: changedPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard !FSEventsMonitor.isExcluded(
                normalizedPath,
                roots: context.excludedRoots,
                components: context.excludedPathComponents
            ) else {
                continue
            }

            let flags = eventFlags[Int(index)]
            acceptedEvents.append(.fileChanged(path: changedPath, flags: flags))
        }

        guard !acceptedEvents.isEmpty else { return }
        let eventsToPublish = acceptedEvents
        context.publicationTracker.submit {
            for event in eventsToPublish {
                await eventBus.publish(event)
            }
        }
    }

    /// - Parameters:
    ///   - excludedRoots: absolute directories whose whole subtree is ignored.
    ///   - excludedPathComponents: directory names ignored wherever they appear in a path
    ///     (e.g. `node_modules`, `.git`). Pass `[]` to disable.
    public init(
        paths: [String],
        excludedRoots: [String] = [],
        excludedPathComponents: Set<String> = FSEventsMonitor.defaultExcludedPathComponents,
        latency: CFTimeInterval = 0.5,
        sourceId: String = "fsEvents",
        queue: DispatchQueue? = nil
    ) {
        self.paths = paths.map {
            URL(fileURLWithPath: $0)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        self.excludedRoots = excludedRoots.map {
            URL(fileURLWithPath: $0)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        self.excludedPathComponents = excludedPathComponents
        self.latency = latency
        self.sourceId = sourceId
        self.queue = queue ?? DispatchQueue(label: "vitapet.fs-events-monitor")
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard streamRef == nil, !paths.isEmpty else {
            return
        }

        let context = CallbackContext(
            eventBus: eventBus,
            excludedRoots: excludedRoots,
            excludedPathComponents: excludedPathComponents
        )
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        callbackContext = contextPointer

        var streamContext = FSEventStreamContext(
            version: 0,
            info: contextPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let streamFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &streamContext,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            streamFlags
        ) else {
            await drainAndReleaseContextIfNeeded()
            return
        }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)

        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
            await drainAndReleaseContextIfNeeded()
            return
        }
    }

    public func stop() async {
        guard let streamRef else {
            await drainAndReleaseContextIfNeeded()
            return
        }

        // Stop the native source first, then wait for callbacks already queued on our
        // serial queue to finish submitting their publications. Closing the tracker
        // before this barrier can drop a callback that began before stop().
        FSEventStreamStop(streamRef)
        queue.sync {}
        publicationTrackerIfPresent()?.stopAccepting()
        FSEventStreamInvalidate(streamRef)
        FSEventStreamRelease(streamRef)
        self.streamRef = nil
        await drainAndReleaseContextIfNeeded()
    }

    /// Exposed for tests; `path` must already be normalized.
    static func isExcluded(_ path: String, roots: [String], components: Set<String>) -> Bool {
        if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        guard !components.isEmpty else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: true)
            .contains { components.contains(String($0)) }
    }

    private func publicationTrackerIfPresent() -> EventPublicationTracker? {
        guard let callbackContext else { return nil }
        return Unmanaged<CallbackContext>
            .fromOpaque(callbackContext)
            .takeUnretainedValue()
            .publicationTracker
    }

    private func drainAndReleaseContextIfNeeded() async {
        guard let publicationTracker = publicationTrackerIfPresent() else { return }
        publicationTracker.stopAccepting()
        await publicationTracker.drain()
        releaseContextIfNeeded()
    }

    private func releaseContextIfNeeded() {
        guard let callbackContext else {
            return
        }

        Unmanaged<CallbackContext>.fromOpaque(callbackContext).release()
        self.callbackContext = nil
    }
}
