import AppKit
import Foundation
import SweetCookieKit

/// Imports Xiaomi MiMo's console session cookies from an existing browser
/// sign-in. The MiMo platform authenticates with cookies only — no bearer
/// token, no API key for the console API — so the session cookie set is the
/// credential. The console's own cookie policy gives `api-platform_serviceToken`
/// and `userId` a 24-hour lifetime, so the cached copy has to be refreshed
/// from the browser before it dies; that is what `importSession` (used by the
/// automatic re-import) is for.
enum MiMoBrowserSession {
    struct Session: Sendable, Equatable {
        let cookieHeader: String
        let sourceLabel: String
    }

    enum ImportError: LocalizedError {
        case noSession(String?)

        var errorDescription: String? {
            switch self {
            case let .noSession(detail):
                if let detail, !detail.isEmpty {
                    return "\(L(.errorMiMoBrowserSessionMissing))（\(detail)）"
                }
                return L(.errorMiMoBrowserSessionMissing)
            }
        }
    }

    /// The console cookies that actually identify the session. Without them the
    /// console answers 401 with a fresh SSO login URL.
    static let requiredCookieNames = ["api-platform_serviceToken", "userId"]

    private static let cachedCredentialAccount = "mimo-browser"
    private static let sourceLabelKey = "tokenbar.miMoBrowserSourceLabel"
    private static let browserKey = "tokenbar.miMoBrowser"
    private static let client = BrowserCookieClient()
    private static let domains = ["xiaomimimo.com", "platform.xiaomimimo.com", "account.xiaomi.com"]
    private static let query = BrowserCookieQuery(domains: domains)

    private static let preferredBrowsers: [Browser] = {
        let preferred: [Browser] = [.chrome, .arc, .safari, .edge, .brave, .firefox]
        return preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
    }()

    /// True when the header carries the console's session cookie.
    static func hasSessionCookie(_ header: String) -> Bool {
        let names = cookieNames(header)
        return requiredCookieNames.contains { names.contains($0) }
    }

    /// Cookie names only — never values — so a diagnostic can show what the
    /// browser actually held without exporting credentials.
    static func cookieNames(_ header: String) -> Set<String> {
        Set(header.split(separator: ";").compactMap { pair -> String? in
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { return nil }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        })
    }

    static func cachedSession() -> Session? {
        guard let raw = CookieKeychainStore.load(provider: cachedCredentialAccount),
              !raw.isEmpty
        else {
            return nil
        }
        guard hasSessionCookie(raw) else {
            UsageStore.log("MiMo cached session has no sign-in cookie; ignoring it")
            return nil
        }
        let source = UserDefaults.standard.string(forKey: sourceLabelKey) ?? L(.browserSession)
        return Session(cookieHeader: raw, sourceLabel: source)
    }

    /// Ordered import candidates: previously-used first, then the stored
    /// source label, then Chrome, then the remaining readable browsers.
    static func browserCandidates() -> [Browser] {
        var out: [Browser] = []
        if let raw = UserDefaults.standard.string(forKey: browserKey),
           let previous = Browser(rawValue: raw)
        {
            out.append(previous)
        }
        if let source = UserDefaults.standard.string(forKey: sourceLabelKey),
           let inferred = preferredBrowsers.first(where: {
               source.localizedCaseInsensitiveContains($0.displayName)
           })
        {
            out.append(inferred)
        }
        out.append(.chrome)
        let available = preferredBrowsers.filter { !client.stores(for: $0).isEmpty }
        out.append(contentsOf: available.filter {
            $0.usesChromiumProfileStore || $0.usesGeckoProfileStore
        })
        out.append(contentsOf: available.filter {
            !($0.usesChromiumProfileStore || $0.usesGeckoProfileStore)
        })
        var seen: Set<Browser> = []
        return out.filter { seen.insert($0).inserted }
    }

    /// Interactive import: try every candidate in order and keep the first
    /// browser that yields a real session. A Keychain denial on one candidate
    /// must not abort the rest.
    static func importSessionInteractively(from _: Browser?) throws -> Session {
        try importSession()
    }

    /// Non-interactive import used by the automatic refresh: the same search,
    /// but without asking the user to pick a browser. It is only attempted
    /// when a session was imported before (the user already granted Full Disk
    /// Access), so a routine refresh never triggers a new permission prompt.
    static func importSession() throws -> Session {
        var lastError: Error?
        var seenNames: [String] = []
        for candidate in browserCandidates() {
            do {
                let sources = try client.records(matching: query, in: candidate)
                for source in sources where !source.records.isEmpty {
                    // Strict domain boundary: the query matches by substring,
                    // so lookalike domains could ride along.
                    let records = CookieDomainFilter.filter(source.records, allowedDomains: domains)
                    guard !records.isEmpty else { continue }
                    let header = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
                        .filter { !$0.name.lowercased().hasPrefix("utm_") }
                        .map { "\($0.name)=\($0.value)" }
                        .joined(separator: "; ")
                    guard !header.isEmpty else { continue }
                    guard hasSessionCookie(header) else {
                        seenNames.append("\(candidate.displayName)/\(source.label): "
                            + cookieNames(header).sorted().joined(separator: ", "))
                        continue
                    }
                    let session = Session(cookieHeader: header, sourceLabel: source.label)
                    cache(session, browser: candidate)
                    return session
                }
            } catch {
                UsageStore.log("MiMo import \(candidate.displayName) skipped: \(error.localizedDescription)")
                lastError = error
            }
        }
        if !seenNames.isEmpty {
            MiMoProvider.writeDiagnostic(
                "import: no sign-in cookie. found: \(seenNames.joined(separator: " | "))")
            throw ImportError.noSession(nil)
        }
        let detail = lastError?.localizedDescription ?? L(.notFound)
        MiMoProvider.writeDiagnostic("import-failed: \(detail)")
        throw ImportError.noSession(detail)
    }

    static func clearCache() {
        CookieKeychainStore.clear(provider: cachedCredentialAccount)
        UserDefaults.standard.removeObject(forKey: sourceLabelKey)
        UserDefaults.standard.removeObject(forKey: browserKey)
    }

    /// Whether a session was ever imported — the marker that the user already
    /// granted the browser read permission.
    static func hasImportedBefore() -> Bool {
        UserDefaults.standard.string(forKey: sourceLabelKey) != nil
    }

    private static func cache(_ session: Session, browser: Browser) {
        guard CookieKeychainStore.store(
            cookie: session.cookieHeader,
            provider: cachedCredentialAccount)
        else {
            return
        }
        UserDefaults.standard.set(session.sourceLabel, forKey: sourceLabelKey)
        UserDefaults.standard.set(browser.rawValue, forKey: browserKey)
    }
}
