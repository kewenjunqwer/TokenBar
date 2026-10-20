import Foundation

// MARK: - Provider

/// Xiaomi MiMo (小米 MiMo) Token Plan usage.
///
/// MiMo publishes no quota API: the console at `platform.xiaomimimo.com` is
/// the only source, and it authenticates with the browser's session cookies
/// (`api-platform_serviceToken` + `userId`) — an `api-key` header does not
/// work. The console's cookie policy gives those cookies a 24-hour lifetime,
/// so the provider re-imports the live browser session when the cached one
/// stops working, and only asks the user to sign in again when the browser
/// itself is signed out.
final class MiMoProvider: UsageProvider {
    let displayName = "小米 MiMo"

    /// The console's private API root. Every path below is a console call,
    /// not a public product API.
    static let apiBase = "https://platform.xiaomimimo.com/api/v1"

    static let usagePath = "/tokenPlan/usage"
    static let detailPath = "/tokenPlan/detail"
    static let balancePath = "/balance"

    /// Console pages the user needs.
    static let consoleURL = URL(string: "https://platform.xiaomimimo.com/#/console/balance")!
    static let planURL = URL(string: "https://platform.xiaomimimo.com/#/token-plan")!
    static let docsURL = URL(string: "https://mimo.mi.com/docs/zh-CN/price/token-plan")!

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    func isAvailable(environment _: [String: String]) -> Bool { true }

    func fetch(environment _: [String: String]) async throws -> ProviderSnapshot {
        let manual = await MainActor.run { self.settings.miMoManualCookie }
        let session: MiMoBrowserSession.Session
        if let header = CookieHeaderNormalizer.normalize(manual) {
            session = MiMoBrowserSession.Session(
                cookieHeader: header, sourceLabel: L(.manualCookie))
        } else if let cached = MiMoBrowserSession.cachedSession() {
            session = cached
        } else {
            throw UsageError.miMoMissingCredentials
        }

        do {
            return try await fetchConsoleUsage(session: session)
        } catch let error as UsageError {
            guard case .miMoInvalidSession = error else { throw error }
            // The cached cookie died (24-hour lifetime). Re-read the browser
            // once — silently, because the user already granted access the
            // first time — and retry with the fresh session.
            guard MiMoBrowserSession.hasImportedBefore() else { throw error }
            UsageStore.log("MiMo session expired; re-importing from the browser")
            do {
                let fresh = try MiMoBrowserSession.importSession()
                return try await fetchConsoleUsage(session: fresh)
            } catch {
                throw UsageError.miMoInvalidSession
            }
        }
    }

    /// One usage read plus one detail read. The detail call only carries the
    /// plan name and the period end, so its failure costs the badge, not the
    /// quota.
    private func fetchConsoleUsage(session: MiMoBrowserSession.Session) async throws -> ProviderSnapshot {
        let usageData = try await fetch(path: Self.usagePath, session: session)
        let usage = try Self.parseUsage(usageData)

        var planCode: String?
        var periodEnd: Date?
        do {
            let detailData = try await fetch(path: Self.detailPath, session: session)
            let detail = try Self.parseDetail(detailData)
            planCode = detail.planCode
            periodEnd = detail.currentPeriodEnd
        } catch {
            UsageStore.log("MiMo tokenPlan/detail failed: \(error.localizedDescription)")
        }

        return Self.makeSnapshot(usage: usage, planCode: planCode, periodEnd: periodEnd)
    }

    private func fetch(path: String, session: MiMoBrowserSession.Session) async throws -> Data {
        guard let url = URL(string: Self.apiBase + path) else {
            throw UsageError.parseFailed("Invalid MiMo console URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Asia/Shanghai", forHTTPHeaderField: "x-timeZone")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "https://platform.xiaomimimo.com/#/console/balance", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.miMoInvalidSession
            }
            throw UsageError.apiError(
                statusCode: response.statusCode,
                message: "MiMo console: \(HTTPErrorSummary.summarize(response.data))")
        }
        // The console answers 200 with a `code` in the body even for 401-ish
        // states, so the envelope has to be inspected as well.
        if let code = Self.envelopeCode(response.data), code == 401 {
            throw UsageError.miMoInvalidSession
        }
        return response.data
    }

    /// The console's envelope code, when the body carries one.
    static func envelopeCode(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let code = object["code"] as? Int { return code }
        if let code = object["code"] as? NSNumber { return code.intValue }
        return nil
    }

    // MARK: - Mapping (static for tests)

    /// The monthly token-pool usage of one account.
    struct Usage: Sendable, Equatable {
        /// Used fraction in [0, 1].
        let usedFraction: Double
        let used: Int?
        let total: Int?
    }

    struct Detail: Sendable, Equatable {
        let planCode: String?
        let currentPeriodEnd: Date?
        let expired: Bool
    }

    static func makeSnapshot(usage: Usage, planCode: String?, periodEnd: Date?) -> ProviderSnapshot {
        let window = UsageWindow(
            label: "Monthly",
            usedPercent: min(100, max(0, usage.usedFraction * 100)),
            used: usage.used,
            total: usage.total,
            resetsAt: periodEnd)
        let plan = PlanSnapshot(
            id: "mimo-token-plan",
            product: .miMo,
            edition: planCode.map { $0.capitalized },
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: [window],
            expiryDate: periodEnd,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: "小米 MiMo",
            authMethod: "cookie",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    // MARK: - Decoding (static for tests)

    static func parseUsage(_ data: Data) throws -> Usage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.parseFailed("MiMo: expected a JSON object")
        }
        guard let payload = object["data"] as? [String: Any],
              let monthUsage = payload["monthUsage"] as? [String: Any]
        else {
            throw UsageError.noPlanUsage("MiMo")
        }

        var usedFraction = Self.doubleValue(monthUsage["percent"])
        var used: Int?
        var total: Int?
        if let items = monthUsage["items"] as? [[String: Any]] {
            // The pool item carries the absolute numbers; the summary percent
            // alone cannot fill the ring's counters.
            for item in items {
                guard let name = item["name"] as? String else { continue }
                guard name.contains("total_token") || name.contains("total") else { continue }
                if let value = Self.intValue(item["used"]) { used = value }
                if let value = Self.intValue(item["limit"]) { total = value }
                if let percent = Self.doubleValue(item["percent"]) { usedFraction = percent }
                break
            }
        }
        guard let usedFraction else {
            throw UsageError.noPlanUsage("MiMo")
        }
        return Usage(usedFraction: usedFraction, used: used, total: total)
    }

    static func parseDetail(_ data: Data) throws -> Detail {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any]
        else {
            throw UsageError.parseFailed("MiMo: expected a JSON object")
        }
        let planCode = (payload["planCode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expired = (payload["expired"] as? NSNumber)?.boolValue ?? false
        return Detail(
            planCode: planCode?.isEmpty == false ? planCode : nil,
            currentPeriodEnd: Self.dateValue(payload["currentPeriodEnd"]),
            expired: expired)
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// `"yyyy-MM-dd HH:mm:ss"` in the console's own (UTC) clock.
    private static func dateValue(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: trimmed)
    }

    static func writeDiagnostic(_ text: String) {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TokenBar", isDirectory: true)
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("mimo-last-response.txt"),
            atomically: true, encoding: .utf8)
    }
}
