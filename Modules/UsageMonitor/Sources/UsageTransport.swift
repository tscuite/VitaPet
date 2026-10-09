import Foundation
import CryptoKit

/// The fingerprint is memory-only; neither tokens nor account identifiers reach the UI or settings file.
struct UsageFetchResult: Sendable {
    let credentialID: String?
    let result: Result<UsageReading, UsageFailure>
}

/// Refuse every redirect, including same-origin: a changed endpoint must be reviewed before credentials follow it.
final class UsageRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum UsageTransport {
    static func retryDate(_ header: String?, now: Date) -> Date {
        let header = header?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let header, let seconds = Double(header), seconds.isFinite, seconds >= 0 {
            return Date(timeIntervalSince1970: min(Double.greatestFiniteMagnitude,
                                                   now.timeIntervalSince1970 + max(60, seconds)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let header, let date = formatter.date(from: header) { return max(now.addingTimeInterval(60), date) }
        return now.addingTimeInterval(60)
    }

    static func credentialID(for request: URLRequest) -> String {
        let identity = ["Authorization", "Cookie", "ChatGPT-Account-Id"]
            .map { request.value(forHTTPHeaderField: $0) ?? "" }.joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fetch(_ provider: UsageProviderID,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      env: [String: String] = ProcessInfo.processInfo.environment,
                      configuration: URLSessionConfiguration = .ephemeral,
                      codexSettings: UsageCodexSettings? = nil) async throws -> UsageFetchResult {
        if provider == .deepseek {
            do { return try await PiLocalSpend.shared.fetch(home: home, env: env) }
            catch is CancellationError { throw CancellationError() }
            catch { return UsageFetchResult(credentialID: nil, result: .failure(.localUsageUnavailable)) }
        }
        var identity: String?
        do {
            let context = try UsageCredentials.context(provider, home: home, env: env)
            identity = credentialID(for: context.request)
            guard !context.isExpired else { throw UsageFailure.credentialExpired }
            let codexSettings = codexSettings ?? (provider == .codex ? UsageCodexSettings.read() : UsageCodexSettings())
            return UsageFetchResult(credentialID: identity, result: .success(try await fetch(
                context.request, provider: provider, configuration: configuration,
                codexSettings: codexSettings, fallbackPlan: context.plan
            )))
        } catch is CancellationError { throw CancellationError() }
        catch let failure as UsageFailure { return UsageFetchResult(credentialID: identity, result: .failure(failure)) }
        catch { return UsageFetchResult(credentialID: identity, result: .failure(.transport)) }
    }

    // Injectable URLSession configuration is internal and used only by offline URLProtocol checks.
    static func fetch(_ request: URLRequest, provider: UsageProviderID,
                      configuration: URLSessionConfiguration = .ephemeral,
                      codexSettings: UsageCodexSettings = UsageCodexSettings(),
                      fallbackPlan: String? = nil) async throws -> UsageReading {
        guard provider != .deepseek else { throw UsageFailure.localUsageUnavailable }
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: UsageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let usageData = try await data(request, session: session)
        guard provider == .codex else { return try UsageParsing.parse(usageData, provider: provider) }

        // Same bearer and account for all three original GETs. Never re-read credentials mid-poll.
        var profile = request
        profile.url = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!
        var resets = request
        resets.url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
        resets.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        // As upstream, start unused resets before decoding extras; then request profile statistics.
        async let resetData = data(resets, session: session)
        var reading = try UsageParsing.parse(usageData, provider: provider, codexSettings: codexSettings)
        do { reading.tokenUsage = try CodexUsage.profileUsage(from: await data(profile, session: session)) }
        catch UsageFailure.googleUnavailable { reading.detail = UsageFailure.googleUnavailable.errorDescription }
        catch {} // Optional endpoint failure must not discard valid quota.
        do { reading.resetCredits = try CodexUsage.resetCredits(from: await resetData) }
        catch UsageFailure.googleUnavailable { reading.detail = UsageFailure.googleUnavailable.errorDescription }
        catch {}
        reading.plan = reading.plan ?? fallbackPlan?.nonEmptyPlan
        try Task.checkCancellation()
        return reading
    }

    /// Each provider GET gets a fresh anonymous Google check, including optional Codex statistics.
    /// DeepSeek never enters this HTTP path. Neither credentials nor a cached success can bypass it.
    private static func checkGoogle(configuration: URLSessionConfiguration) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = configuration.protocolClasses // Offline URLProtocol seam only; never copy provider headers.
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 5
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: UsageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var probe = UsageCredentials.get("https://www.google.com/generate_204", headers: [:])
        probe.timeoutInterval = 5
        do {
            try Task.checkCancellation()
            let (_, response) = try await session.bytes(for: probe)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 204,
                  response.url == probe.url else { throw UsageFailure.googleUnavailable }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw UsageFailure.googleUnavailable
        }
    }

    // Also used by the explicitly opted-in same-response comparison; it cannot bypass the Google gate.
    static func data(_ request: URLRequest, session: URLSession) async throws -> Data {
        do {
            try Task.checkCancellation()
            try await checkGoogle(configuration: session.configuration)
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw UsageFailure.invalidResponse }
            if http.statusCode == 429 {
                throw UsageFailure.rateLimited(retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: Date()))
            }
            if http.statusCode == 401 || http.statusCode == 403 { throw UsageFailure.notConnected }
            guard (200..<300).contains(http.statusCode) else { throw UsageFailure.http(http.statusCode) }
            guard response.expectedContentLength <= 1_048_576 else { throw UsageFailure.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw UsageFailure.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as UsageFailure { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw UsageFailure.transport }
    }
}
