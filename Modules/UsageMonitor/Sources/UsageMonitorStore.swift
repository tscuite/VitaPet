import AppKit
import Foundation
import Combine

@MainActor
public final class UsageMonitorStore: ObservableObject {
    @Published public private(set) var settings: UsageBarSettings
    @Published public private(set) var readings: [UsageReading]
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var refreshing: Set<UsageProviderID> = []
    @Published public private(set) var settingsError: String?

    private struct Document: Codable {
        var version = 1
        var settings: UsageBarSettings
        var retryAfter: [String: Date] = [:]
    }
    private let fileURL: URL
    private let fetch: @Sendable (UsageProviderID) async throws -> UsageFetchResult
    private var credentialIDs: [UsageProviderID: String] = [:]
    private var retryAfter: [String: Date] = [:]
    private var running = false
    private var blockedPersistence = false
    private var generation = 0
    private var pollTimer: Timer?
    private var fetchTasks: [UsageProviderID: Task<Void, Never>] = [:]
    private var deadlineTask: Task<Void, Never>?
    var inFlightForTesting: Set<UsageProviderID> { Set(fetchTasks.keys) }
    private let pollingNow: () -> Date
    private var lastAttempt: Date?
    private var lastWorkFinished: Date?
    private var codexIsBusy = false
    private var codexActivity: CodexActivityMonitor?
    private let observesCodexActivity: Bool
    private var wakeObserver: NSObjectProtocol?

    public convenience init(directory: URL? = nil) {
        self.init(directory: directory, observesCodexActivity: true, read: { try await UsageTransport.fetch($0) })
    }

    // Test seam never exposed to UI; checks inject data rather than touching a real account.
    convenience init(directory: URL?, fetch: @escaping @Sendable (UsageProviderID) async throws -> UsageReading) {
        self.init(directory: directory, read: { provider in
            let identity = "fixture-" + provider.rawValue
            do { return UsageFetchResult(credentialID: identity, result: .success(try await fetch(provider))) }
            catch is CancellationError { throw CancellationError() }
            catch { return UsageFetchResult(credentialID: identity, result: .failure(error as? UsageFailure ?? .transport)) }
        })
    }

    init(directory: URL?, observesCodexActivity: Bool = false, pollingNow: @escaping () -> Date = Date.init,
         read: @escaping @Sendable (UsageProviderID) async throws -> UsageFetchResult) {
        self.pollingNow = pollingNow
        self.observesCodexActivity = observesCodexActivity
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VitaPet", isDirectory: true)
        fileURL = directory.appendingPathComponent("usage-monitor.json")
        self.fetch = read
        var loaded = UsageBarSettings()
        var loadError: String?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try UsageCredentials.file(fileURL)
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard document.version == 1 else { throw UsageFailure.invalidResponse }
                loaded = document.settings
                retryAfter = document.retryAfter.filter {
                    UsageProviderID(rawValue: $0.key) != nil && $0.key != UsageProviderID.deepseek.rawValue && $0.value.timeIntervalSince1970.isFinite
                }
            } catch {
                blockedPersistence = true
                loadError = "Usage settings could not be read. The original file was preserved; move or repair usage-monitor.json before saving settings."
            }
        }
        loaded.normalize()
        settings = loaded
        readings = loaded.providers.map { UsageReading(provider: $0, status: .disabled, detail: "Monitoring is off.") }
        settingsError = loadError
    }

    public func start() {
        guard !running else { return }
        running = true
        rebuildReadings()
        beginPolling()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func stop() async {
        running = false
        generation += 1
        stopPolling()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        let previous = Array(fetchTasks.values)
        cancelReads()
        for task in previous { await task.value }
        // A start while shutdown was awaiting must not erase the new generation.
        guard !running else { return }
        fetchTasks = [:]; isRefreshing = false
        rebuildReadings()
    }

    public func updateSettings(_ change: (inout UsageBarSettings) -> Void) {
        var candidate = settings
        change(&candidate); candidate.normalize()
        guard persist(candidate) else { return }
        let reordered = settings.providers != candidate.providers
        let needsRestart = settings.monitoringEnabled != candidate.monitoringEnabled || Set(settings.providers) != Set(candidate.providers)
        settings = candidate
        guard needsRestart else {
            if reordered { rebuildReadings() }
            return
        }
        generation += 1
        stopPolling()
        cancelReads()
        rebuildReadings()
        beginPolling()
    }

    public func refresh(_ provider: UsageProviderID? = nil) {
        guard running, settings.monitoringEnabled, provider != nil || !isRefreshing else { return }
        let selected = provider.map { settings.providers.contains($0) ? [$0] : [] } ?? settings.providers
        guard !selected.isEmpty else { return }
        let now = pollingNow()
        // One task per source, as upstream: a stuck provider cannot monopolize unrelated refreshes.
        let eligible = selected.filter { id in
            if let task = fetchTasks[id], !task.isCancelled { return false }
            if id != .deepseek, let retry = retryAfter[id.rawValue], retry > now {
                setFailure(.rateLimited(retry), for: id)
                return false
            }
            return true
        }
        if provider == nil || !eligible.isEmpty { lastAttempt = now }
        guard !eligible.isEmpty else { return }
        isRefreshing = true
        refreshing.formUnion(eligible)
        let expectedGeneration = generation
        let fetch = self.fetch
        for id in eligible {
            let previous = fetchTasks[id]
            fetchTasks[id] = Task { [weak self] in
                // Wait for a cancelled predecessor for this source, never queue overlapping credential reads.
                await previous?.value
                defer { self?.finishRefresh(id, expectedGeneration) }
                guard !Task.isCancelled else { return }
                let result: UsageFetchResult
                do { result = try await fetch(id) }
                catch is CancellationError { return }
                catch { result = UsageFetchResult(credentialID: nil, result: .failure(error as? UsageFailure ?? .transport)) }
                guard let self, !Task.isCancelled, self.running, self.settings.monitoringEnabled,
                      self.generation == expectedGeneration, self.settings.providers.contains(id) else { return }
                // A failed request for account B must never retain account A's cached quota.
                if result.credentialID == nil || self.credentialIDs[id] != result.credentialID {
                    self.replace(UsageReading(provider: id))
                }
                self.credentialIDs[id] = result.credentialID
                switch result.result {
                case .success(let reading):
                    self.replace(reading)
                    if self.retryAfter.removeValue(forKey: id.rawValue) != nil { _ = self.persist(self.settings) }
                case .failure(let failure):
                    if case .rateLimited(let retry) = failure {
                        self.retryAfter[id.rawValue] = retry
                        _ = self.persist(self.settings)
                    }
                    self.setFailure(failure, for: id)
                }
                // CodeNotch holds a single-provider press for 380ms after the result, including errors.
                // Keep the task registered during feedback so fast repeated clicks cannot stack reads.
                if provider != nil { try? await Task.sleep(for: .milliseconds(380)) }
            }
        }
        if deadlineTask == nil {
            deadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(UsageRefreshSchedule.deadline)) } catch { return }
                self?.abandonRefresh()
            }
        }
    }

    /// Upstream's 60-second deadline releases the pass, NOT its still-blocked reads.
    func abandonRefresh() {
        guard isRefreshing else { return }
        for id in fetchTasks.keys { setFailure(.transport, for: id) }
        refreshing.subtract(fetchTasks.keys)
        isRefreshing = false
        deadlineTask?.cancel(); deadlineTask = nil
    }

    private func persist(_ candidate: UsageBarSettings) -> Bool {
        guard !blockedPersistence else { return false }
        do {
            let document = Document(settings: candidate, retryAfter: retryAfter)
            let data = try JSONEncoder().encode(document)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            settingsError = nil
            return true
        } catch {
            settingsError = "Usage settings could not be saved. The previous settings remain in effect."
            return false
        }
    }

    private func beginPolling() {
        guard running, settings.monitoringEnabled, !settings.providers.isEmpty else { return }
        if observesCodexActivity, settings.providers.contains(.codex) {
            let activity = CodexActivityMonitor()
            activity.onBusyChange = { [weak self] in self?.noteCodexWorkState(isBusy: $0) }
            codexActivity = activity
            activity.start()
        }
        refresh()
        // The upstream tick checks dates, not credentials. Idle ticks make no network requests.
        let timer = Timer(timeInterval: UsageRefreshSchedule.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
        codexActivity?.stop(); codexActivity = nil
        codexIsBusy = false; lastWorkFinished = nil
    }

    func tick() {
        guard running, settings.monitoringEnabled else { return }
        markStale()
        let now = pollingNow()
        let waited = lastAttempt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard UsageRefreshSchedule.shouldRefresh(
            isBusy: codexIsBusy, sinceLastAttempt: waited,
            idleInterval: UsageRefreshSchedule.idleInterval, busyInterval: UsageRefreshSchedule.busyInterval,
            resetDue: UsageRefreshSchedule.hasWindowRolledOver(in: readings, since: lastAttempt, at: now)
        ) else { return }
        refresh()
    }

    /// Original attention-triggered refresh; crossing several rings shares one 15-second budget.
    public func refreshBecauseSomeoneIsLooking() {
        let waited = lastAttempt.map { pollingNow().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard UsageRefreshSchedule.shouldRefreshOnEvent(sinceLastRefresh: waited,
                                                       spacing: UsageRefreshSchedule.onLookInterval) else { return }
        refresh()
    }

    func noteCodexWorkState(isBusy: Bool) {
        guard running, settings.monitoringEnabled, settings.providers.contains(.codex) else { return }
        let wasBusy = codexIsBusy
        codexIsBusy = isBusy
        guard wasBusy, !isBusy else { return }
        let now = pollingNow()
        let waited = lastWorkFinished.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard UsageRefreshSchedule.shouldRefreshOnEvent(sinceLastRefresh: waited,
                                                       spacing: UsageRefreshSchedule.busyInterval) else { return }
        lastWorkFinished = now
        refresh(.codex)
    }

    private func cancelReads() {
        for task in fetchTasks.values { task.cancel() }
        deadlineTask?.cancel(); deadlineTask = nil
        refreshing.removeAll()
        isRefreshing = false
    }

    private func finishRefresh(_ id: UsageProviderID, _ expectedGeneration: Int) {
        if expectedGeneration != generation {
            if fetchTasks[id]?.isCancelled == true { fetchTasks.removeValue(forKey: id) }
            return
        }
        fetchTasks.removeValue(forKey: id)
        refreshing.remove(id)
        if fetchTasks.isEmpty {
            deadlineTask?.cancel(); deadlineTask = nil
            isRefreshing = false
        }
    }

    private func rebuildReadings() {
        readings = settings.providers.map { id in
            guard running && settings.monitoringEnabled else {
                return UsageReading(provider: id, status: .disabled, detail: "Monitoring is off.")
            }
            return readings.first(where: { $0.provider == id && $0.status != .disabled }) ?? UsageReading(provider: id)
        }
    }
    private func replace(_ reading: UsageReading) {
        if let index = readings.firstIndex(where: { $0.provider == reading.provider }) { readings[index] = reading }
    }
    private func setFailure(_ error: UsageFailure, for provider: UsageProviderID) {
        var reading = readings.first(where: { $0.provider == provider }) ?? UsageReading(provider: provider)
        switch error {
        case .notConnected, .incompatiblePiCredential:
            // Do not show the previous account's reading after a sign-out/token rejection.
            reading = UsageReading(provider: provider, status: .notConnected)
        case .googleUnavailable:
            reading.status = reading.updatedAt == nil ? .failed : .stale
        case .rateLimited(let date):
            // While backing off we do not reread credentials, so cannot confirm the cached account.
            reading = UsageReading(provider: provider, status: .rateLimited)
            reading.detail = (error.errorDescription ?? "") + " Retry after \(date.formatted())."
        default:
            if let updatedAt = reading.updatedAt {
                reading.status = pollingNow().timeIntervalSince(updatedAt) > UsageRefreshSchedule.staleAfter ? .stale : .ready
            } else { reading.status = .failed }
        }
        if reading.detail == nil || reading.status != .rateLimited { reading.detail = error.errorDescription }
        if reading.updatedAt != nil { reading.detail = "Last successful reading (cached). " + (reading.detail ?? "") }
        replace(reading)
    }
    private func markStale() {
        let threshold = pollingNow().addingTimeInterval(-UsageRefreshSchedule.staleAfter)
        guard readings.contains(where: { $0.status == .ready && ($0.updatedAt.map { $0 < threshold } ?? false) }) else { return }
        readings = readings.map { reading in
            var result = reading
            if result.status == .ready, let updatedAt = result.updatedAt, updatedAt < threshold {
                result.status = .stale; result.detail = "Last successful reading (cached)."
            }
            return result
        }
    }

    /// Deterministic fixture for isolated previews/tests only; never used by start or refresh.
    public static var previewReadings: [UsageReading] {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        return zip(UsageProviderID.allCases, [0.38, 0.81, 0.52, 1.0, 0.09, 0.0]).map { id, value in
            if id == .deepseek {
                return UsageReading(provider: id, status: .ready, updatedAt: date,
                    localSpend: UsageLocalSpend(today: .init(usd: 1, records: 2, reference: 2),
                        last7Days: .init(usd: 4, records: 8, reference: 8), last30Days: .init(usd: 8, records: 16, reference: 16),
                        total: .init(usd: 8, records: 16, reference: 16), scannedFiles: 4, discoveredFiles: 4))
            }
            return UsageReading(provider: id, status: .ready,
                         limits: [UsageLimit(id: "preview", title: "Preview window", usedFraction: value)], updatedAt: date)
        }
    }
}
