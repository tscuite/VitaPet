import Darwin
import Foundation

struct ShuttleMenuEntry: Equatable, Sendable {
    let title: String
    let action: String?
    var children: [ShuttleMenuEntry] = []

    var isSeparator: Bool { title == "---" }
}

enum ShuttlePlugin {
    enum Failure: Error, Equatable {
        case missing, invalidOutput, launchFailed, timedOut
        case exited(Int32)
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VitaPet/Plugins/Shuttle/shuttle.1d.sh")
    }

    // shortcut: only Shuttle's one-level menus and self-script actions; expand for another plugin only when needed.
    static func parse(_ output: String, pluginURL: URL) throws -> [ShuttleMenuEntry] {
        let lines = output.components(separatedBy: .newlines)
        guard output.utf8.count <= 65_536, lines.count <= 256,
              let divider = lines.firstIndex(of: "---") else {
            throw Failure.invalidOutput
        }
        var entries: [ShuttleMenuEntry] = []
        for rawLine in lines.dropFirst(divider + 1) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let isChild = line.hasPrefix("--") && line != "---"
            guard !line.hasPrefix("----") else { throw Failure.invalidOutput }
            let row = (isChild ? String(line.dropFirst(2)) : line)
                .trimmingCharacters(in: .whitespaces)
            let parts = row.components(separatedBy: " | ")
            guard parts.count <= 2, parts.count == 2 || !row.contains("|"),
                  let title = parts.first, !title.isEmpty, title.count <= 256 else {
                throw Failure.invalidOutput
            }
            var action: String?
            if parts.count == 2 {
                let prefix = "bash=\(pluginURL.path) param1="
                let suffix = " terminal=false"
                guard parts[1].hasPrefix(prefix), parts[1].hasSuffix(suffix) else {
                    throw Failure.invalidOutput
                }
                let value = String(parts[1].dropFirst(prefix.count).dropLast(suffix.count))
                guard validAction(value) else { throw Failure.invalidOutput }
                action = value
            }
            guard title != "---" || action == nil else { throw Failure.invalidOutput }
            let entry = ShuttleMenuEntry(title: title, action: action)
            if isChild {
                guard let parent = entries.last, parent.action == nil, !parent.isSeparator else {
                    throw Failure.invalidOutput
                }
                entries[entries.count - 1].children.append(entry)
            } else {
                entries.append(entry)
            }
        }
        guard entries.contains(where: { !$0.isSeparator }) else { throw Failure.invalidOutput }
        return entries
    }

    static func validAction(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    static func run(pluginURL: URL, action: String? = nil) throws -> String {
        guard FileManager.default.isReadableFile(atPath: pluginURL.path) else { throw Failure.missing }
        if let action, !validAction(action) { throw Failure.invalidOutput }

        // A private file avoids pipe deadlocks and keeps output bounded without logging script contents.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VitaPet-Shuttle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Failure.launchFailed
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [pluginURL.path] + (action.map { [$0] } ?? [])
        process.currentDirectoryURL = pluginURL.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["SWIFTBAR_PLUGIN_PATH"] = pluginURL.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = action == nil ? output : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.launchFailed }

        let deadline = ProcessInfo.processInfo.systemUptime + (action == nil ? 5 : 120)
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stop(process)
                throw Failure.timedOut
            }
            if ((try? output.offset()) ?? 0) > 65_536 {
                stop(process)
                throw Failure.invalidOutput
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.exited(process.terminationStatus)
        }
        if action != nil { return "" }
        let input = try FileHandle(forReadingFrom: outputURL)
        defer { try? input.close() }
        let data = try input.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw Failure.invalidOutput
        }
        return text
    }

    private static func stop(_ process: Process) {
        // Foundation normally gives the child its own group; never signal VitaPet's group.
        let pid = process.processIdentifier
        if getpgid(pid) == pid {
            kill(-pid, SIGKILL)
        } else if process.isRunning {
            kill(pid, SIGKILL)
        }
        process.waitUntilExit()
    }
}
