import Foundation
import UIKit

/// In-app diagnostic log (LOG RETRIEVAL LAW, owner order
/// 2026-11-18): every build ships a way to get its log out, so
/// faults are fixed from evidence instead of blind hunting.
/// Settings → "Gửi log chẩn đoán" exports the buffer as a text
/// file through the iOS share sheet.
///
/// Design:
/// • Ring buffer of the last ~2,000 lines, in memory only. The
///   log is a debugging aid for the CURRENT session, not a
///   record — nothing is persisted to disk by the logger itself.
/// • Thread safety: a plain NSLock around every access, the same
///   pattern ImageCacheManager uses. An actor was rejected: the
///   call sites are synchronous (UIKit error surfaces, the
///   non-isolated image cache, timer closures) and forcing an
///   async hop at each one would scatter Tasks through code
///   paths that must stay exactly as they are. The class is
///   therefore `@unchecked Sendable` with ALL mutable state —
///   buffer and date formatters alike — touched only while the
///   lock is held.
/// • REDACTION (hard rule): debrid tokens, the MediaFusion
///   manifest URL and signed-URL query strings must NEVER reach
///   this buffer. Call sites log hosts and paths via
///   `urlForLog(_:)` (scheme + host + path, query and fragment
///   stripped, credentials dropped) and refer to secrets only
///   by configured yes/no. There is deliberately no API that
///   takes a raw URL.
final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 2000

    /// Formatters are created once and only ever used while
    /// `lock` is held (see append/export), so they need no
    /// synchronization of their own.
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f
    }()

    private init() {}

    // MARK: - Logging

    static func log(_ category: String, _ message: String) {
        shared.append(category: category, message: message)
    }

    private func append(category: String, message: String) {
        lock.withLock {
            lines.append("\(timeFormatter.string(from: Date())) [\(category)] \(message)")
            if lines.count > capacity {
                lines.removeFirst(lines.count - capacity)
            }
        }
    }

    // MARK: - Export

    static func exportText() -> String {
        shared.export()
    }

    private func export() -> String {
        let (snapshot, exportedAt) = lock.withLock { (lines, exportDateFormatter.string(from: Date())) }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let header = [
            "JTV diagnostic log",
            "Exported: \(exportedAt)",
            "App: JTV \(version) (\(build))",
            "System: iOS \(UIDevice.current.systemVersion) on \(Self.deviceModel)",
            "Lines: \(snapshot.count) (oldest first, times are local)",
            "---",
        ]
        return (header + snapshot).joined(separator: "\n") + "\n"
    }

    /// Hardware identifier (e.g. "iPhone17,2") — more useful in
    /// a log than UIDevice's marketing-free "iPhone".
    private static var deviceModel: String {
        var sys = utsname()
        uname(&sys)
        return Mirror(reflecting: sys.machine).children.reduce("") { acc, child in
            guard let byte = child.value as? Int8, byte != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(bitPattern: byte)))
        }
    }

    // MARK: - Redaction helper

    /// The ONLY shape in which a URL may enter the log:
    /// scheme://host[:port]/path — query and fragment stripped,
    /// any embedded credentials dropped. Non-URL targets
    /// (episode ids such as "jtvhash:…" or "jtvstreams:…")
    /// collapse to their scheme-like prefix so the payload —
    /// a hash, a signed id — is never written either.
    static func urlForLog(_ urlString: String) -> String {
        if let comps = URLComponents(string: urlString),
           let scheme = comps.scheme, let host = comps.host, !host.isEmpty {
            var out = "\(scheme)://\(host)"
            if let port = comps.port { out += ":\(port)" }
            out += comps.path
            return out
        }
        if let colon = urlString.firstIndex(of: ":") {
            return String(urlString[..<colon]) + ":…"
        }
        return "…"
    }
}
