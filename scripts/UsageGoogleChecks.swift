import Foundation
@testable import UsageMonitor

private final class GoogleFixture: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case ready, status(Int), failure(URLError.Code), wrongOrigin, hang, failAfterFirst }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var mode: Mode = .ready
        var requests: [URLRequest] = []
        func reset(_ mode: Mode) { lock.withLock { self.mode = mode; requests = [] } }
        func record(_ request: URLRequest) -> Mode {
            lock.withLock {
                requests.append(request)
                if case .failAfterFirst = mode {
                    return requests.filter { $0.url?.host == "www.google.com" }.count <= 1 ? .ready : .status(503)
                }
                return mode
            }
        }
        func snapshot() -> [URLRequest] { lock.withLock { requests } }
    }
    private static let state = State()
    static func reset(_ mode: Mode) { state.reset(mode) }
    static func requests() -> [URLRequest] { state.snapshot() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.record(request)
        if request.url?.host == "www.google.com" {
            precondition(request.url?.absoluteString == "https://www.google.com/generate_204" && request.httpMethod == "GET")
            precondition(request.timeoutInterval <= 5 && request.cachePolicy == .reloadIgnoringLocalCacheData)
            for header in ["Authorization", "Cookie", "ChatGPT-Account-Id", "OpenAI-Beta"] {
                precondition(request.value(forHTTPHeaderField: header) == nil, "Google probe cannot inherit provider credentials/headers")
            }
            let status: Int
            switch mode {
            case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code)); return
            case .hang: return
            case .status(let value): status = value
            default: status = 204
            }
            let url: URL
            if case .wrongOrigin = mode { url = URL(string: "https://portal.invalid/generate_204")! } else { url = request.url! }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Location": "https://portal.invalid"] )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        precondition(request.url?.host == "chatgpt.com", "No other endpoint, including a redirect destination, may be contacted")
        let path = request.url!.path
        let name = path.hasSuffix("/usage") ? "usage" : path.hasSuffix("profiles/me") ? "profile" : "resets"
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Modules/UsageMonitor/Tests/Fixtures")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! Data(contentsOf: fixtures.appendingPathComponent("codex-\(name).json")))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
func googleGateChecks(_ root: URL) async throws {
    let home = root.appendingPathComponent("google-gate-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoogleFixture.self]
        // Deliberate session-level secrets, to prove the anonymous probe doesn't just strip request headers.
        config.httpAdditionalHeaders = ["Authorization": "fixture-must-not-reach-google", "Cookie": "fixture-cookie", "ChatGPT-Account-Id": "fixture-account"]
        return config
    }
    func quotaRequest() -> URLRequest {
        UsageCredentials.get("https://chatgpt.com/backend-api/wham/usage", headers: ["Authorization": "Bearer fixture-codex", "ChatGPT-Account-Id": "fixture-account"])
    }
    for mode: GoogleFixture.Mode in [.status(200), .status(302), .status(429), .status(503), .wrongOrigin,
                                    .failure(.cannotFindHost), .failure(.timedOut), .failure(.serverCertificateUntrusted), .failure(.notConnectedToInternet)] {
        for provider in UsageProviderID.allCases where provider != .deepseek {
            GoogleFixture.reset(mode)
            do {
                _ = try await UsageTransport.fetch(quotaRequest(), provider: provider, configuration: configuration())
                preconditionFailure("Unreachable/non-204 Google must prevent every network provider request")
            } catch UsageFailure.googleUnavailable {}
            let requests = GoogleFixture.requests()
            precondition(requests.count == 1 && requests[0].url?.host == "www.google.com", "Fail closed: only the anonymous check ran")
        }
    }
    GoogleFixture.reset(.ready)
    for _ in 0..<2 {
        let reading = try await UsageTransport.fetch(quotaRequest(), provider: .codex, configuration: configuration())
        precondition(reading.tokenUsage != nil && reading.resetCredits != nil)
    }
    let requests = GoogleFixture.requests()
    precondition(requests.count == 12 && requests.filter { $0.url?.host == "www.google.com" }.count == 6,
                 "Every Codex GET, including profile/reset statistics, needs a new Google check; no cached allow result")
    GoogleFixture.reset(.failAfterFirst)
    let partial = try await UsageTransport.fetch(quotaRequest(), provider: .codex, configuration: configuration())
    precondition(!partial.limits.isEmpty && partial.tokenUsage == nil && partial.resetCredits == nil
                 && partial.detail == UsageFailure.googleUnavailable.errorDescription,
                 "Losing Google after primary quota prevents auxiliaries, keeps valid quota and reports the skipped requests")
    precondition(GoogleFixture.requests().filter { $0.url?.host != "www.google.com" }.count == 1)
    GoogleFixture.reset(.hang)
    let pending = Task { try await UsageTransport.fetch(quotaRequest(), provider: .codex, configuration: configuration()) }
    for _ in 0..<100 where GoogleFixture.requests().isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    pending.cancel()
    do { _ = try await pending.value; preconditionFailure("Cancellation must interrupt the Google check") } catch is CancellationError {}
    precondition(GoogleFixture.requests().count == 1, "Cancelled check cannot release a provider request")
    GoogleFixture.reset(.status(503))
    let local = try await UsageTransport.fetch(.deepseek, home: home, env: [:], configuration: configuration())
    let localReading = try local.result.get()
    precondition(localReading.localSpend != nil && GoogleFixture.requests().isEmpty,
                 "DeepSeek bypasses both Google and provider HTTP, even when Google is unavailable")
    GoogleFixture.reset(.ready)
    let store = UsageMonitorStore(directory: root.appendingPathComponent("google-gate-store"), fetch: { provider in
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GoogleFixture.self]
        let request = UsageCredentials.get("https://chatgpt.com/backend-api/wham/usage", headers: [:])
        return try await UsageTransport.fetch(request, provider: provider, configuration: config)
    })
    store.updateSettings { $0.monitoringEnabled = true; $0.providers = [.codex] }
    store.start()
    while store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
    precondition(store.readings.first?.status == .ready)
    let updated = store.readings.first?.updatedAt
    GoogleFixture.reset(.failure(.notConnectedToInternet))
    store.refresh(.codex)
    while store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
    precondition(store.readings.first?.status == .stale && store.readings.first?.updatedAt == updated
                 && store.readings.first?.detail?.contains(UsageFailure.googleUnavailable.errorDescription!) == true,
                 "A failed Google check is visible, and cached data is dated/stale rather than a fresh success")
    precondition(GoogleFixture.requests().count == 1 && store.refreshing.isEmpty)
    GoogleFixture.reset(.ready)
    store.refresh(.codex)
    while store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
    precondition(store.readings.first?.status == .ready && store.readings.first?.detail == nil, "Next refresh rechecks and recovers; no Google failure backoff is persisted")
    await store.stop()
    GoogleFixture.reset(.status(503))
    store.refresh(.codex)
    precondition(GoogleFixture.requests().isEmpty, "Stopped monitoring sends no Google or account requests")
    print("PASS: fresh anonymous Google gate for every network GET, HTTP/DNS/TLS/timeout/cancellation failures, recovery, visible cached state and complete DeepSeek exemption.")
}
