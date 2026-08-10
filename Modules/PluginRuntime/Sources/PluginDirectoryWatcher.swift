import CoreServices
import Foundation

final class PluginDirectoryWatcher: @unchecked Sendable {
    typealias ChangeHandler = @Sendable (URL) async -> Void

    private final class CallbackContext {
        let directories: [URL]
        let handler: ChangeHandler

        init(directories: [URL], handler: @escaping ChangeHandler) {
            self.directories = directories
            self.handler = handler
        }
    }

    private let directories: [URL]
    private let handler: ChangeHandler
    private let queue = DispatchQueue(label: "vitapet.plugin-watcher")
    private var streamRef: FSEventStreamRef?
    private var callbackContext: UnsafeMutableRawPointer?

    private static let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
        guard let clientCallBackInfo else {
            return
        }

        let context = Unmanaged<CallbackContext>
            .fromOpaque(clientCallBackInfo)
            .takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: CFArray.self) as NSArray

        for index in 0..<numEvents {
            guard let rawPath = paths[index] as? String else {
                continue
            }

            let changedURL = URL(fileURLWithPath: rawPath)
            guard let pluginURL = pluginBundleURL(for: changedURL, directories: context.directories) else {
                continue
            }

            let handler = context.handler
            Task {
                await handler(pluginURL)
            }
        }
    }

    init(directories: [URL], handler: @escaping ChangeHandler) {
        self.directories = directories
        self.handler = handler
    }

    func start() {
        guard streamRef == nil, !directories.isEmpty else {
            return
        }

        let context = CallbackContext(directories: directories, handler: handler)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        self.callbackContext = contextPointer

        var streamContext = FSEventStreamContext(
            version: 0,
            info: contextPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = directories.map(\.path) as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes
        )

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &streamContext,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )

        guard let stream else {
            releaseContextIfNeeded()
            return
        }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// 停止监听并释放回调上下文。
    ///
    /// 注意：本方法**不得在 watcher 的回调队列 `queue` 上调用** —— 否则内部的
    /// `queue.sync {}` 屏障会死锁。当前唯一调用方 `PluginManager.stop()` 在主线程触发，安全。
    func stop() {
        guard let streamRef else {
            releaseContextIfNeeded()
            return
        }

        FSEventStreamStop(streamRef)
        FSEventStreamInvalidate(streamRef)
        FSEventStreamRelease(streamRef)
        self.streamRef = nil
        // 回调在 queue 上执行并用 takeUnretainedValue 读 context；
        // 先排空队列，确保没有在跑的回调再释放 context，避免 use-after-free。
        queue.sync {}
        releaseContextIfNeeded()
    }

    deinit {
        stop()
    }

    private func releaseContextIfNeeded() {
        guard let callbackContext else {
            return
        }

        Unmanaged<CallbackContext>.fromOpaque(callbackContext).release()
        self.callbackContext = nil
    }

    private static func pluginBundleURL(for changedURL: URL, directories: [URL]) -> URL? {
        if changedURL.pathExtension == "vitaplugin" {
            return changedURL
        }

        for directory in directories {
            let directoryPath = directory.standardizedFileURL.path
            let changedPath = changedURL.standardizedFileURL.path

            guard changedPath.hasPrefix(directoryPath + "/") else {
                continue
            }

            let relativePath = String(changedPath.dropFirst(directoryPath.count + 1))
            guard let firstComponent = relativePath.split(separator: "/").first else {
                continue
            }

            let candidate = directory.appendingPathComponent(String(firstComponent), isDirectory: true)
            if candidate.pathExtension == "vitaplugin" {
                return candidate
            }
        }

        return nil
    }
}
