import Foundation
import MetricKit
import NoDonutsCore
import os

// Owner: krusty (with gordon, diagnostics ND-044). ND-108: local-only crash summary.
//
// PRIVACY (hard requirement): everything here stays on this Mac. Nothing is uploaded, no
// network is used. MetricKit delivers its payloads locally to the app; we keep only a
// compact summary (when, Mach exception type/code, signal, app version/build) and
// DROP the rest: no call stacks, no termination-reason text (it can contain file paths
// with the user name), no memory-region info. The summary is only ever shown in
// "Copy diagnostics", which the user copies themselves.
//
// Two sources, both local:
//  1. MetricKit (`MXMetricManager`, macOS 12+): crash diagnostics are handed to the
//     subscriber on the launch after a crash. Stored in UserDefaults, capped at the
//     last `maxRecords`, deduplicated (the past-payloads re-read at each launch).
//     UNVERIFIED for an ad-hoc / Developer-ID (non-App-Store) build: macOS may not
//     deliver payloads to it at all, and they may depend on the system's analytics
//     setting. Hence source 2.
//  2. Fallback, read at diagnostics time: the newest
//     `~/Library/Logs/DiagnosticReports/NoDonuts-*.ips` crash reports that macOS writes
//     for every app. Only the timestamp, versions and exception type/signal are read.

/// One crash, reduced to what a triager needs. Numbers and fixed labels only.
struct CrashSummaryRecord: Codable, Equatable, Sendable {
    /// MetricKit: end of the payload's reporting window (not the exact crash time).
    var date: Date
    var exceptionType: Int?
    var exceptionCode: Int?
    var signal: Int?
    var appVersion: String
    var appBuild: String

    var dedupeKey: String {
        "\(Int(date.timeIntervalSince1970))|\(exceptionType ?? -1)|\(exceptionCode ?? -1)|\(signal ?? -1)|\(appVersion)|\(appBuild)"
    }
}

/// Receives MetricKit diagnostic payloads and persists the compact summaries.
/// MetricKit calls back on its own queue, so the store is lock-guarded.
final class CrashSummaryCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let defaultsKey = "crashSummaries.v1"
    static let maxRecords = 5

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let log = Logger(subsystem: Log.subsystem, category: Log.Category.app)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// Subscribe and ingest anything MetricKit already has. Call once at launch; the
    /// caller must keep a strong reference (MetricKit doesn't retain subscribers reliably).
    func start() {
        let manager = MXMetricManager.shared
        manager.add(self)
        ingest(manager.pastDiagnosticPayloads)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        ingest(payloads)
    }

    // MARK: Store

    /// The stored summaries, newest first.
    func records() -> [CrashSummaryRecord] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    private func ingest(_ payloads: [MXDiagnosticPayload]) {
        var incoming: [CrashSummaryRecord] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                incoming.append(CrashSummaryRecord(
                    date: payload.timeStampEnd,
                    exceptionType: crash.exceptionType?.intValue,
                    exceptionCode: crash.exceptionCode?.intValue,
                    signal: crash.signal?.intValue,
                    appVersion: crash.applicationVersion,
                    appBuild: crash.metaData.applicationBuildVersion))
            }
        }
        guard !incoming.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var all = load()
        let known = Set(all.map(\.dedupeKey))
        let fresh = incoming.filter { !known.contains($0.dedupeKey) }
        guard !fresh.isEmpty else { return }
        all.append(contentsOf: fresh)
        all.sort { $0.date > $1.date }
        all = Array(all.prefix(Self.maxRecords))
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        log.notice("MetricKit reported \(fresh.count, privacy: .public) crash(es); summary kept locally (last \(Self.maxRecords, privacy: .public))")
    }

    /// Must be called with `lock` held.
    private func load() -> [CrashSummaryRecord] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([CrashSummaryRecord].self, from: data) else { return [] }
        return decoded.sorted { $0.date > $1.date }
    }
}

/// Builds the diagnostics section. Pure formatting plus a bounded local file read, so
/// call it off the main thread (the .ips files can be ~100 KB each).
enum CrashSummaryReport {
    /// How many of the newest crash-report files to summarize.
    static let maxReportFiles = 3

    static func lines(metricKit records: [CrashSummaryRecord],
                      reportsDirectory: URL = defaultReportsDirectory) -> [String] {
        var lines: [String] = []
        lines.append("[Crashes (local only, never uploaded)]")
        if records.isEmpty {
            lines.append("  MetricKit: none received (may not be delivered to non-App-Store builds)")
        } else {
            lines.append("  MetricKit (last \(CrashSummaryCollector.maxRecords), newest first; date = end of reporting window):")
            for record in records {
                lines.append("    \(iso8601(record.date))  \(machExceptionName(record.exceptionType)) code \(record.exceptionCode.map(String.init) ?? "?"), \(signalName(record.signal)), app \(record.appVersion) (\(record.appBuild))")
            }
        }
        let reports = crashReportSummaries(in: reportsDirectory)
        if reports.isEmpty {
            lines.append("  Crash report files: none (\(reportsDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))/NoDonuts-*.ips)")
        } else {
            lines.append("  Crash report files (newest \(maxReportFiles)):")
            lines.append(contentsOf: reports.map { "    \($0)" })
        }
        return lines
    }

    static var defaultReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// One line per newest `NoDonuts-*.ips`: timestamp, app version, exception type/signal.
    /// Reads nothing else from the file (no stacks, no paths, no incident IDs).
    static func crashReportSummaries(in directory: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let files: [(url: URL, modified: Date)] = names
            .filter { $0.hasPrefix("NoDonuts-") && $0.hasSuffix(".ips") }
            .map { directory.appendingPathComponent($0) }
            .map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, modified)
            }
            .sorted { $0.modified > $1.modified }
        // Filter to real crash reports FIRST, then cap (review fix: newer non-crash .ips
        // files — hangs, resource reports — must not crowd out an older crash).
        return Array(files.lazy.compactMap { summarizeIPS(at: $0.url) }.prefix(maxReportFiles))
    }

    /// An .ips file is a one-line JSON header followed by a JSON body.
    static func summarizeIPS(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let headerData = data[data.startIndex..<newline]
        let bodyData = data[data.index(after: newline)...]
        guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else { return nil }
        // bug_type 309 = crash. Other types (hangs, resource reports) aren't crashes.
        if let bugType = header["bug_type"] as? String, bugType != "309" { return nil }
        let timestamp = header["timestamp"] as? String ?? "unknown time"
        let version = header["app_version"] as? String ?? "?"
        let build = header["build_version"] as? String ?? "?"
        var exception = "exception unknown"
        if let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
           let info = body["exception"] as? [String: Any] {
            let type = info["type"] as? String ?? "?"
            let signal = info["signal"] as? String ?? "?"
            exception = "\(type), \(signal)"
        }
        return "\(timestamp)  \(exception), app \(version) (\(build))"
    }

    // MARK: Labels

    static func machExceptionName(_ type: Int?) -> String {
        guard let type else { return "exception ?" }
        switch type {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 4: return "EXC_EMULATION"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        case 13: return "EXC_CORPSE_NOTIFY"
        default: return "exception \(type)"
        }
    }

    static func signalName(_ signal: Int?) -> String {
        guard let signal else { return "signal ?" }
        switch signal {
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 15: return "SIGTERM"
        default: return "signal \(signal)"
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
