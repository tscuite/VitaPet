import Foundation
import CryptoKit
import Darwin

public struct UsageLocalSpend: Codable, Equatable, Sendable {
    enum PriceSource { case recorded, configured, reference }
    public struct Amount: Codable, Equatable, Sendable {
        public var usd: Decimal?
        public var records: Int
        public var unpriced: Int
        public var recorded: Int
        public var configured: Int
        public var reference: Int
        public init(usd: Decimal? = nil, records: Int = 0, unpriced: Int = 0,
                    recorded: Int = 0, configured: Int = 0, reference: Int = 0) {
            self.usd = usd; self.records = records; self.unpriced = unpriced
            self.recorded = recorded; self.configured = configured; self.reference = reference
        }
        mutating func add(_ cost: Decimal?, source: PriceSource) {
            records += 1
            guard let cost else { unpriced += 1; return }
            usd = (usd ?? 0) + cost
            switch source {
            case .recorded: recorded += 1
            case .configured: configured += 1
            case .reference: reference += 1
            }
        }
    }
    public var today: Amount
    public var last7Days: Amount
    public var last30Days: Amount
    public var total: Amount
    public var incomplete: Bool
    public var scannedFiles: Int
    public var discoveredFiles: Int
    public init(today: Amount = Amount(), last7Days: Amount = Amount(), last30Days: Amount = Amount(), total: Amount = Amount(),
                incomplete: Bool = false, scannedFiles: Int = 0, discoveredFiles: Int = 0) {
        self.today = today; self.last7Days = last7Days; self.last30Days = last30Days; self.total = total; self.incomplete = incomplete
        self.scannedFiles = scannedFiles; self.discoveredFiles = discoveredFiles
    }
}

/// Pi usage accounting informed by CC Switch 5ae6ad3 (MIT); see THIRD_PARTY_NOTICES.md.
/// Only billing metadata survives parsing. No transcript, credential or aggregate is written to disk.
actor PiLocalSpend {
    static let shared = PiLocalSpend()
    static let maxFileBytes = 64 * 1024 * 1024
    static let maxLineBytes = 1024 * 1024
    static let maxRecords = 50_000
    private var root: URL?
    private var cache: [URL: Cached] = [:]
    private struct Record {
        let id: String
        let date: Date
        let provider: String
        let model: String
        let requestedModel: String
        let reported: Decimal?
        let tokens: [Decimal]?
    }
    private struct Cached {
        let signature: String
        let records: [Record]
        let incomplete: Bool
        var reusable = false
    }

    func fetch(home: URL, env: [String: String], now: Date = Date(), calendar: Calendar = .current,
               byteBudget: Int = maxFileBytes) throws -> UsageFetchResult {
        try Task.checkCancellation()
        let agent = try UsagePiCredentials.directory(home: home, env: env)
        let directory = try sessionDirectory(agent: agent, home: home, env: env).resolvingSymlinksInPath().standardizedFileURL
        if root != directory { cache.removeAll(); root = directory }
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw UsageFailure.localUsageUnavailable }
            cache.removeAll()
            return result(UsageLocalSpend(), directory: directory, now: now)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw UsageFailure.localUsageUnavailable }
        var incomplete = false
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants], errorHandler: { _, _ in incomplete = true; return true }) else {
            throw UsageFailure.localUsageUnavailable
        }
        var files: [(url: URL, info: stat)] = []
        var paths = 0, discoveredFiles = 0
        while let url = walker.nextObject() as? URL {
            try Task.checkCancellation()
            paths += 1
            guard paths <= 4096, files.count < 1024 else { incomplete = true; break }
            guard walker.level <= 8 else { walker.skipDescendants(); incomplete = true; continue }
            if url.pathExtension == "jsonl" { discoveredFiles += 1 }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { incomplete = true; continue }
            let kind = metadata.st_mode & S_IFMT
            if kind == S_IFLNK { walker.skipDescendants(); incomplete = true; continue }
            guard url.pathExtension == "jsonl" else { continue }
            guard kind == S_IFREG, metadata.st_size >= 0, metadata.st_size <= Self.maxFileBytes else {
                incomplete = true; continue
            }
            files.append((url, metadata))
        }
        let present = Set(files.map(\.url))
        cache = cache.filter { present.contains($0.key) }
        // New/active files first, so a bounded initial scan doesn't hide today's work behind old logs.
        files.sort { $0.info.st_mtimespec.tv_sec == $1.info.st_mtimespec.tv_sec
            ? $0.url.path < $1.url.path : $0.info.st_mtimespec.tv_sec > $1.info.st_mtimespec.tv_sec }
        var remaining = max(0, byteBudget)
        var cachedRecords = cache.values.reduce(0) { $0 + $1.records.count }
        for file in files {
            try Task.checkCancellation()
            let signature = Self.signature(file.info)
            if let cached = cache[file.url], cached.signature == signature, cached.reusable { continue }
            let oldCount = cache.removeValue(forKey: file.url)?.records.count ?? 0
            cachedRecords -= oldCount
            guard file.info.st_size <= remaining else { incomplete = true; continue }
            remaining -= Int(file.info.st_size)
            // ponytail: rescan changed files, at most 64 MiB/pass; add append cursors if large active logs dominate.
            let scanned = try Self.scan(file.url, metadata: file.info, recordLimit: Self.maxRecords - cachedRecords)
            cache[file.url] = scanned
            cachedRecords += scanned.records.count
        }
        let prices: [String: [String: Any]]
        do { prices = try Self.prices(agent: agent) }
        catch { prices = [:] } // Missing/invalid prices are accounted for as unpriced records, not a broken log scan.
        var summary = UsageLocalSpend(incomplete: incomplete || cache.values.contains(where: \.incomplete),
            scannedFiles: cache.values.filter { !$0.incomplete }.count, discoveredFiles: discoveredFiles)
        let today = calendar.startOfDay(for: now)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86_400)
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86_400)
        var seen = Set<String>()
        for file in files {
            for record in cache[file.url]?.records ?? [] {
                try Task.checkCancellation()
                guard record.date <= now, seen.insert(record.id).inserted else { continue }
                var cost = record.reported
                var source = UsageLocalSpend.PriceSource.recorded
                if cost == nil {
                    cost = Self.calculate(record.tokens, price: prices[record.provider + "\n" + record.model])
                    // A gateway alias may use its configured rate only when it still names the actual model family.
                    if cost == nil, DeepSeekReferencePricing.family(record.model) == DeepSeekReferencePricing.family(record.requestedModel) {
                        cost = Self.calculate(record.tokens, price: prices[record.provider + "\n" + record.requestedModel])
                    }
                    source = .configured
                }
                if cost == nil {
                    cost = Self.calculate(record.tokens, price: DeepSeekReferencePricing.rates(for: record.model))
                    source = .reference
                }
                summary.total.add(cost, source: source)
                if record.date >= thirtyDaysAgo { summary.last30Days.add(cost, source: source) }
                if record.date >= sevenDaysAgo { summary.last7Days.add(cost, source: source) }
                if record.date >= today { summary.today.add(cost, source: source) }
            }
        }
        if summary.total.records > 0, !summary.incomplete {
            if summary.today.records == 0 { summary.today.usd = 0 }
            if summary.last7Days.records == 0 { summary.last7Days.usd = 0 }
            if summary.last30Days.records == 0 { summary.last30Days.usd = 0 }
        }
        try Task.checkCancellation()
        return result(summary, directory: directory, now: now)
    }

    private func result(_ summary: UsageLocalSpend, directory: URL, now: Date) -> UsageFetchResult {
        let identity = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return UsageFetchResult(credentialID: "local-pi-" + identity,
            result: .success(UsageReading(provider: .deepseek, status: .ready, updatedAt: now, localSpend: summary)))
    }

    private func sessionDirectory(agent: URL, home: URL, env: [String: String]) throws -> URL {
        func absolute(_ path: String) throws -> URL {
            guard path.utf8.count < 4096 else { throw UsageFailure.localUsageUnavailable }
            if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
            guard path.hasPrefix("/") else { throw UsageFailure.localUsageUnavailable }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let path = env["PI_CODING_AGENT_SESSION_DIR"], !path.isEmpty { return try absolute(path) }
        struct Settings: Decodable { let sessionDir: String? }
        let file = agent.appendingPathComponent("settings.json")
        var info = stat()
        if lstat(file.path, &info) == 0 {
            let settings = try JSONDecoder().decode(Settings.self, from: UsageCredentials.file(file))
            if let path = settings.sessionDir, !path.isEmpty { return try absolute(path) }
        } else if errno != ENOENT { throw UsageFailure.localUsageUnavailable }
        return agent.appendingPathComponent("sessions")
    }

    private static func signature(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private static func scan(_ url: URL, metadata: stat, recordLimit: Int) throws -> Cached {
        let signature = signature(metadata)
        var records: [Record] = [], incomplete = false, headerSeen = false, hitRecordLimit = false
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return Cached(signature: signature, records: [], incomplete: true) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
              Self.signature(opened) == signature else { return Cached(signature: signature, records: [], incomplete: true) }
        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            do {
                let entry = try UsageParsing.object(line)
                if !headerSeen {
                    guard entry["type"] as? String == "session", entry["id"] is String else { throw UsageFailure.invalidResponse }
                    headerSeen = true; return
                }
                if let record = try record(entry) { records.append(record) }
            } catch { incomplete = true }
        }
        var buffer = Data(), dropping = false
        var remaining = Int(metadata.st_size)
        do {
            while remaining > 0 {
                try Task.checkCancellation()
                guard records.count < recordLimit else { incomplete = true; hitRecordLimit = true; break }
                let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                guard !chunk.isEmpty else { incomplete = true; break }
                remaining -= chunk.count
                var start = chunk.startIndex
                while let newline = chunk[start...].firstIndex(of: 10) {
                    if !dropping, buffer.count + newline - start <= maxLineBytes {
                        buffer.append(contentsOf: chunk[start..<newline])
                        if records.count < recordLimit { consume(buffer) } else { incomplete = true; hitRecordLimit = true }
                    } else { incomplete = true }
                    buffer.removeAll(keepingCapacity: true); dropping = false
                    start = chunk.index(after: newline)
                }
                if !dropping, buffer.count + chunk.endIndex - start <= maxLineBytes {
                    buffer.append(contentsOf: chunk[start...])
                } else { dropping = true; buffer.removeAll(keepingCapacity: true); incomplete = true }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { incomplete = true }
        if !buffer.isEmpty || dropping || !headerSeen { incomplete = true } // Never charge an unfinished JSONL tail.
        var finished = stat()
        guard fstat(fd, &finished) == 0, Self.signature(finished) == signature else {
            return Cached(signature: signature, records: [], incomplete: true) // Don't publish mixed pre/post-rewrite totals.
        }
        // A fully read malformed/tail-incomplete file cannot improve until it changes; don't starve later files by rereading it.
        return Cached(signature: signature, records: records, incomplete: incomplete, reusable: remaining == 0 && !hitRecordLimit)
    }

    private static func record(_ entry: [String: Any]) throws -> Record? {
        let kind = entry["type"] as? String
        let message: [String: Any]
        if kind == "message" {
            guard let value = entry["message"] as? [String: Any], value["role"] as? String == "assistant",
                  value["stopReason"] as? String != "pending" else { return nil }
            message = value
        } else if kind == "usage" { message = entry }
        else { return nil } // Tool/compaction totals have no reliable model attribution and can include nested calls.
        func label(_ value: Any?) -> String? {
            guard let value = value as? String, value.utf8.count <= 512 else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let model = label(message["responseModel"]) ?? label(message["model"]) else { return nil }
        let name = DeepSeekReferencePricing.family(model)
        guard name == "deepseek" || name.hasPrefix("deepseek-") || name.hasPrefix("deepseek_") else { return nil }
        guard let id = label(entry["id"]), let date = date(entry["timestamp"]) ?? date(message["timestamp"]) else {
            throw UsageFailure.invalidResponse
        }
        let usage = message["usage"] as? [String: Any] ?? [:]
        let cost = usage["cost"] as? [String: Any] ?? [:]
        var reported = decimal(cost["total"])
        if reported == nil || reported == 0 {
            let components = ["input", "output", "cacheRead", "cacheWrite"].compactMap { decimal(cost[$0]) }
            if components.count == 4 { reported = components.reduce(0, +) }
        }
        var values = ["input", "output", "cacheRead", "cacheWrite"].map { decimal(usage[$0]) }
        values.append(usage["cacheWrite1h"] == nil ? 0 : decimal(usage["cacheWrite1h"]))
        let integers = values.allSatisfy { value in
            value.map { $0 == Decimal(NSDecimalNumber(decimal: $0).int64Value) } ?? false
        }
        let tokens = integers && values[4]! <= values[3]! ? values.compactMap { $0 } : nil
        if reported == 0, tokens == nil || tokens!.contains(where: { $0 > 0 }) { reported = nil }
        if let currency = cost["currency"], currency as? String != "USD" { reported = nil }
        if let value = reported, value > 1_000_000_000 { reported = nil }
        let identity = [kind ?? "", id, String(date.timeIntervalSince1970)].joined(separator: "\n")
        return Record(id: identity, date: date, provider: label(message["provider"]) ?? "", model: model,
                      requestedModel: label(message["model"]) ?? model, reported: reported, tokens: tokens)
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = UsageParsing.number(value), number <= 253_402_300_799_999 {
            return Date(timeIntervalSince1970: number / 1000) // Pi message timestamps are milliseconds.
        }
        guard let text = value as? String, text.utf8.count < 80 else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        guard let value = UsageParsing.number(value), value <= 1_000_000_000 else { return nil }
        return Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func prices(agent: URL) throws -> [String: [String: Any]] {
        let path = agent.appendingPathComponent("models.json")
        var info = stat()
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw UsageFailure.localUsageUnavailable }
            return [:]
        }
        let root = try UsageParsing.object(UsageCredentials.file(path))
        let providers = root["providers"] as? [String: [String: Any]] ?? [:]
        var prices: [String: [String: Any]] = [:]
        for (provider, config) in providers {
            for model in config["models"] as? [[String: Any]] ?? [] {
                if let id = model["id"] as? String, let cost = model["cost"] as? [String: Any] {
                    prices[provider + "\n" + id] = cost.filter { ["input", "output", "cacheRead", "cacheWrite", "tiers"].contains($0.key) }
                }
            }
            for (id, model) in config["modelOverrides"] as? [String: [String: Any]] ?? [:] {
                if let cost = model["cost"] as? [String: Any] {
                    let key = provider + "\n" + id
                    let overrides = cost.filter { ["input", "output", "cacheRead", "cacheWrite", "tiers"].contains($0.key) }
                    prices[key] = (prices[key] ?? [:]).merging(overrides) { _, override in override }
                }
            }
        }
        return prices
    }

    private static func calculate(_ tokens: [Decimal]?, price: [String: Any]?) -> Decimal? {
        guard let tokens, var price else { return nil }
        let input = tokens[0] + tokens[2] + tokens[3]
        let tiers = (price["tiers"] as? [[String: Any]] ?? []).compactMap { tier -> (Decimal, [String: Any])? in
            guard let threshold = decimal(tier["inputTokensAbove"]), input > threshold else { return nil }
            return (threshold, tier)
        }
        if let tier = tiers.max(by: { $0.0 < $1.0 }) { price = tier.1 }
        let rates = ["input", "output", "cacheRead", "cacheWrite"].compactMap { decimal(price[$0]) }
        guard rates.count == 4, rates.contains(where: { $0 > 0 }) else { return nil }
        // Pi input is already fresh input; reasoning is already in output. Neither is counted twice.
        let base = zip(tokens.prefix(4), rates).reduce(Decimal(0)) { $0 + $1.0 * $1.1 }
        let cost = (base - tokens[4] * rates[3] + tokens[4] * rates[0] * 2) / 1_000_000
        return cost <= 1_000_000_000 ? cost : nil
    }
}
