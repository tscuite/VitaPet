import CoreServices
import Foundation

public actor FSEventsMonitor: EventSource {
    public let sourceId: String

    private final class CallbackContext: @unchecked Sendable {
        let eventBus: EventBus
        let excludedRoots: [String]
        let publicationTracker = EventPublicationTracker()

        init(eventBus: EventBus, excludedRoots: [String]) {
            self.eventBus = eventBus
            self.excludedRoots = excludedRoots
        }
    }

    private let paths: [String]
    private let excludedRoots: [String]
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
            guard !context.excludedRoots.contains(where: { normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/") }) else {
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

    public init(
        paths: [String],
        excludedRoots: [String] = [],
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
        self.latency = latency
        self.sourceId = sourceId
        self.queue = queue ?? DispatchQueue(label: "vitapet.fs-events-monitor")
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard streamRef == nil, !paths.isEmpty else {
            return
        }

        let context = CallbackContext(eventBus: eventBus, excludedRoots: excludedRoots)
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
