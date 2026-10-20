import Foundation

// MARK: - Credentials

/// Reads a MiniMax API key from the environment. Settings (Keychain) values
/// take precedence; this is the fallback.
enum MiniMaxCredentialResolver {
    static let apiKeyKeys = [
        "MINIMAX_API_KEY",
        "MINIMAX_CODING_API_KEY",
        "MINIMAX_TOKEN_PLAN_API_KEY",
    ]

    static func apiKey(environment: [String: String]) -> String? {
        for key in apiKeyKeys {
            guard var value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - Provider

/// MiniMax (M Plan / Token Plan) usage.
///
/// The plan quota is documented: `GET {host}/v1/token_plan/remains` with
/// `Authorization: Bearer <API key>` returns the remaining allowance for the
/// rolling 5-hour window and the weekly window. No browser session is
/// involved, so — unlike the console-cookie providers — this path never
/// expires and never asks the user to sign in again.
///
/// The vendor renamed its China hosts (`minimaxi.com` → `minimax.cn`), so the
/// request walks a short candidate list and remembers the host that answered.
final class MiniMaxProvider: UsageProvider {
    let displayName = "MiniMax"

    /// Documented quota endpoint (M Plan / Token Plan FAQ).
    static let quotaPath = "/v1/token_plan/remains"

    /// Candidate API hosts, China first. The first one that answers wins and
    /// is remembered for the next refresh.
    static let candidateHosts = [
        "https://api.minimax.cn",
        "https://www.minimax.cn",
        "https://api.minimaxi.com",
        "https://api.minimax.io",
        "https://www.minimax.io",
    ]

    /// Where the remembered, working host is stored.
    static let hostKey = "tokenbar.minimaxHost"

    /// Console pages the user needs: the plan page and the usage page.
    static let consoleURL = URL(string: "https://platform.minimax.cn/console/usage")!
    static let planURL = URL(string: "https://platform.minimax.cn/console/plan")!

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    func isAvailable(environment _: [String: String]) -> Bool { true }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let storedKey = await MainActor.run { Self.trimmed(self.settings.miniMaxAPIKey) }
        let apiKey = storedKey ?? MiniMaxCredentialResolver.apiKey(environment: environment)
        guard let apiKey else {
            throw UsageError.miniMaxMissingCredentials
        }
        return try await fetchQuota(apiKey: apiKey)
    }

    /// Walks the candidate hosts until one answers. A host that 404s/405s is
    /// skipped (wrong path for that deployment); a 401 is a credential problem
    /// and stops the walk immediately.
    private func fetchQuota(apiKey: String) async throws -> ProviderSnapshot {
        let remembered = UserDefaults.standard.string(forKey: Self.hostKey)
        var hosts = Self.candidateHosts
        if let remembered, let index = hosts.firstIndex(of: remembered) {
            hosts.remove(at: index)
            hosts.insert(remembered, at: 0)
        }

        var lastError: Error?
        for host in hosts {
            guard let url = URL(string: host + Self.quotaPath) else { continue }
            do {
                let snapshot = try await fetchQuota(url: url, apiKey: apiKey)
                UserDefaults.standard.set(host, forKey: Self.hostKey)
                return snapshot
            } catch let error as UsageError {
                switch error {
                case .miniMaxInvalidToken:
                    // The key itself is rejected; another host would say the same.
                    throw error
                case let .apiError(status, _):
                    if status == 401 || status == 403 { throw UsageError.miniMaxInvalidToken }
                    lastError = error
                default:
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? UsageError.miniMaxMissingCredentials
    }

    private func fetchQuota(url: URL, apiKey: String) async throws -> ProviderSnapshot {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.miniMaxInvalidToken
            }
            throw UsageError.apiError(
                statusCode: response.statusCode,
                message: "MiniMax quota: \(HTTPErrorSummary.summarize(response.data))")
        }

        let payload = try Self.parse(response.data)
        if let code = payload.baseResp?.statusCode, code != 0 {
            // 1004 is the vendor's "no/invalid credential" code.
            if code == 1004 || code == 1008 {
                throw UsageError.miniMaxInvalidToken
            }
            throw UsageError.apiError(
                statusCode: code,
                message: payload.baseResp?.statusMsg ?? "MiniMax quota")
        }

        let entries = payload.modelRemains ?? payload.data?.modelRemains ?? []
        guard !entries.isEmpty else {
            throw UsageError.noPlanUsage("MiniMax")
        }
        return try Self.makeSnapshot(entries: entries)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Mapping (static for tests)

    /// One plan per model family, so a model with its own pool keeps its own
    /// rings instead of being averaged away.
    static func makeSnapshot(entries: [QuotaResponse.ModelRemains]) throws -> ProviderSnapshot {
        var plans: [PlanSnapshot] = []
        for entry in entries {
            var windows: [UsageWindow] = []
            if let window = Self.window(
                total: entry.intervalTotal?.value,
                remaining: entry.intervalUsage?.value,
                remainingPercent: entry.intervalRemainingPercent?.value,
                label: "5-hour",
                resetsAt: Self.date(from: entry.endTime?.value)
                    ?? Self.date(from: entry.remainsTime?.value, isSecondsFromNow: true))
            {
                windows.append(window)
            }
            if let window = Self.window(
                total: entry.weeklyTotal?.value,
                remaining: entry.weeklyUsage?.value,
                remainingPercent: entry.weeklyRemainingPercent?.value,
                label: "Weekly",
                resetsAt: Self.date(from: entry.weeklyEndTime?.value))
            {
                windows.append(window)
            }
            guard !windows.isEmpty else { continue }
            plans.append(PlanSnapshot(
                id: "minimax-\(entry.modelName ?? "plan")",
                product: .miniMax,
                edition: entry.modelName,
                tier: nil,
                seatID: nil,
                subscribed: true,
                windows: windows.sorted { $0.sortRank < $1.sortRank },
                expiryDate: nil,
                errorMessage: nil))
        }
        guard !plans.isEmpty else {
            throw UsageError.noPlanUsage("MiniMax")
        }
        return ProviderSnapshot(
            providerName: "MiniMax",
            authMethod: "apikey",
            plans: plans,
            updatedAt: Date(),
            errorMessage: nil)
    }

    /// Builds one window. The vendor publishes *remaining* counts under a
    /// field named `..._usage_count`, so the used amount is derived from the
    /// total. When the total is absent the vendor sends a remaining percent
    /// instead.
    static func window(
        total: Double?,
        remaining: Double?,
        remainingPercent: Double?,
        label: String,
        resetsAt: Date?
    ) -> UsageWindow? {
        if let total, total > 0, let remaining {
            let used = max(0, min(total, total - remaining))
            return UsageWindow(
                label: label,
                usedPercent: min(100, max(0, used / total * 100)),
                used: Int(used.rounded()),
                total: Int(total.rounded()),
                resetsAt: resetsAt)
        }
        if let remainingPercent {
            let percent = min(100, max(0, remainingPercent))
            return UsageWindow(
                label: label,
                usedPercent: min(100, max(0, 100 - percent)),
                used: nil,
                total: nil,
                resetsAt: resetsAt)
        }
        return nil
    }

    private static func date(from value: Double?, isSecondsFromNow: Bool = false) -> Date? {
        guard let value, value > 0 else { return nil }
        if isSecondsFromNow {
            return Date(timeIntervalSinceNow: value)
        }
        // The vendor sends epoch milliseconds.
        return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }

    // MARK: - Decoding (static for tests)

    /// A number that may arrive as a JSON number or as a decimal string.
    struct LenientNumber: Decodable, Sendable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                value = Double(text.trimmingCharacters(in: .whitespaces))
            } else {
                value = try? container.decode(Double.self)
            }
        }
    }

    struct QuotaResponse: Decodable, Sendable {
        struct BaseResp: Decodable, Sendable {
            let statusCode: Int?
            let statusMsg: String?

            enum CodingKeys: String, CodingKey {
                case statusCode = "status_code"
                case statusMsg = "status_msg"
            }
        }

        struct Data: Decodable, Sendable {
            let modelRemains: [ModelRemains]?

            enum CodingKeys: String, CodingKey {
                case modelRemains = "model_remains"
            }
        }

        struct ModelRemains: Decodable, Sendable {
            let modelName: String?
            let startTime: LenientNumber?
            let endTime: LenientNumber?
            let remainsTime: LenientNumber?
            let intervalTotal: LenientNumber?
            let intervalUsage: LenientNumber?
            let intervalRemainingPercent: LenientNumber?
            let weeklyTotal: LenientNumber?
            let weeklyUsage: LenientNumber?
            let weeklyRemainingPercent: LenientNumber?
            let weeklyEndTime: LenientNumber?

            enum CodingKeys: String, CodingKey {
                case modelName = "model_name"
                case startTime = "start_time"
                case endTime = "end_time"
                case remainsTime = "remains_time"
                case intervalTotal = "current_interval_total_count"
                case intervalUsage = "current_interval_usage_count"
                case intervalRemainingPercent = "current_interval_remaining_percent"
                case weeklyTotal = "current_weekly_total_count"
                case weeklyUsage = "current_weekly_usage_count"
                case weeklyRemainingPercent = "current_weekly_remaining_percent"
                case weeklyEndTime = "weekly_end_time"
            }
        }

        let baseResp: BaseResp?
        /// The API-key path returns the list at the top level; the console
        /// path nests it under `data`.
        let modelRemains: [ModelRemains]?
        let data: Data?

        enum CodingKeys: String, CodingKey {
            case baseResp = "base_resp"
            case modelRemains = "model_remains"
            case data
        }
    }

    static func parse(_ data: Data) throws -> QuotaResponse {
        do {
            return try JSONDecoder().decode(QuotaResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed("MiniMax quota: \(error.localizedDescription)")
        }
    }

    static func writeDiagnostic(_ text: String) {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TokenBar", isDirectory: true)
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("minimax-last-response.txt"),
            atomically: true, encoding: .utf8)
    }
}
