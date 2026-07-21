import AppKit
import Foundation

@MainActor
public final class WorkspaceMonitor: EventSource, @unchecked Sendable {
    public let sourceId: String = "workspace"

    private let notificationCenter: NotificationCenter
    private var activateObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?
    private var publicationTracker: EventPublicationTracker?

    public init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard activateObserver == nil, deactivateObserver == nil else {
            return
        }

        let publicationTracker = EventPublicationTracker()
        self.publicationTracker = publicationTracker
        activateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleId = application.bundleIdentifier,
                let appName = application.localizedName
            else {
                return
            }

            publicationTracker.publish(.appActivated(bundleId: bundleId, appName: appName), to: eventBus)
        }

        deactivateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleId = application.bundleIdentifier,
                let appName = application.localizedName
            else {
                return
            }

            publicationTracker.publish(.appDeactivated(bundleId: bundleId, appName: appName), to: eventBus)
        }
    }

    public func stop() async {
        publicationTracker?.stopAccepting()
        if let activateObserver {
            notificationCenter.removeObserver(activateObserver)
            self.activateObserver = nil
        }

        if let deactivateObserver {
            notificationCenter.removeObserver(deactivateObserver)
            self.deactivateObserver = nil
        }
        await publicationTracker?.drain()
        publicationTracker = nil
    }
}
