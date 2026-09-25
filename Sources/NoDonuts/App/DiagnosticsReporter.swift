import AppKit
import AVFoundation
import CoreLocation
import OSLog
import NoDonutsCore

// Owner: gordon — local, privacy-safe diagnostics (ND-044).
//
// Produces a plaintext support summary the user can copy from Settings and paste
// into a bug report. Everything is gathered on-device from OS state; NOTHING is
// sent anywhere.
//
// PRIVACY (hard requirement): the output NEVER contains face embeddings, image
// data, or Wi-Fi SSID strings. Trusted networks appear as a COUNT only.
// Permissions appear as coarse status labels only. The log tail is filtered to
// our own subsystem and is limited to recent, current-process entries.

/// Gathers a privacy-safe diagnostics summary and can copy it to the pasteboard.
///
/// Stateless: all live values (presence state, config, enrollment store) are
/// injected per call so krusty can wire this to a "Copy diagnostics" menu item
/// without the reporter reaching into app singletons.
@MainActor
struct DiagnosticsReporter {

    /// Build the privacy-safe plaintext report.
    ///
    /// - Parameters:
    ///   - state: the current presence state (from the engine).
    ///   - config: the effective tunable config (tick / grace / threshold / …).
    ///   - store: enrollment store — only its `isEnrolled` flag is read.
    ///   - identity: identity-recognition status (ND-073) — model version strings only.
    ///   - locationStatus: the current `CLAuthorizationStatus` (status label only).
    ///   - trustedNetworkCount: number of trusted Wi-Fi SSIDs — a COUNT, never names.
    ///   - notificationStatusDescription: optional pre-fetched notification
    ///     authorization label (that API is async; the caller fetches it and
    ///     passes it in). `nil` → omitted.
    ///   - lockCapability: lock self-test result (ND-058) — mechanism names only.
    ///   - cameraUnavailableReason: last camera unavailable reason (ND-075), a fixed string.
    ///   - now: injectable clock for the timestamp (defaults to `Date()`).
    /// - Returns: a multi-line plaintext report with no PII.
    func diagnosticsSummary(
        state: PresenceState,
        config: Config,
        descriptor: FaceEmbeddingModelDescriptor,
        store: EnrollmentStoring,
        identity: IdentityStatus,
        locationStatus: CLAuthorizationStatus,
        trustedNetworkCount: Int,
        notificationStatusDescription: String? = nil,
        lockCapability: LockCapability,
        cameraUnavailableReason: String? = nil,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []

        lines.append("No Donuts — diagnostics")
        lines.append("Generated: \(iso8601(now))")
        lines.append("")

        // --- App / system identity ---
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("[App]")
        lines.append("  Version:   \(shortVersion) (build \(build))")
        lines.append("  Bundle ID: \(bundleID)")
        lines.append("  macOS:     \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("")

        // --- Permissions (coarse status labels only) ---
        lines.append("[Permissions]")
        lines.append("  Camera:   \(cameraStatusDescription())")
        lines.append("  Location: \(locationStatusDescription(locationStatus))")
        if let notif = notificationStatusDescription {
            lines.append("  Notifications: \(notif)")
        }
        lines.append("")

        // --- Enrollment (yes/no only — never the embeddings) ---
        lines.append("[Enrollment]")
        lines.append("  Enrolled: \(store.isEnrolled ? "yes" : "no")")
        lines.append("  Identity: \(Self.identityStatusDescription(identity))")
        lines.append("")

        // --- Presence + effective config ---
        lines.append("[Presence]")
        lines.append("  State: \(presenceStateDescription(state))")
        lines.append("  Lock mechanisms: \(Self.lockCapabilityDescription(lockCapability))")
        lines.append("  Camera: built-in only (ADR-0015); last unavailable reason: \(cameraUnavailableReason ?? "none")")
        let lidLine: String
        switch LidState.current() {
        case .open:   lidLine = "open (camera unavailable \(Int(config.maxCameraUnavailableSeconds))s → lock)"
        case .closed: lidLine = "closed (camera-unavailable never locks)"
        case .noLid:  lidLine = "no lid (desktop; camera-unavailable never locks)"
        }
        lines.append("  Lid: \(lidLine)")
        lines.append("")
        lines.append("[Config (raw base values from store)]")
        lines.append("  tickIntervalSeconds:            \(config.tickIntervalSeconds)")
        lines.append("  graceSeconds:                   \(config.graceSeconds)")
        lines.append("  consecutiveAbsentTicksToLock:   \(config.consecutiveAbsentTicksToLock)")
        lines.append("  maxConsecutiveErrorsBeforeAbsent: \(config.maxConsecutiveErrorsBeforeAbsent)")
        lines.append("  maxCallAssumedPresentSeconds:   \(config.maxCallAssumedPresentSeconds)")
        lines.append("  throttleOnBattery:              \(config.throttleOnBattery)")
        lines.append("")

        // --- Effective recognizer values ---
        // The recognizer resolves these LIVE per tick from UserDefaults (they can be
        // overridden without a rebuild), so the raw Config base above may differ from
        // what is actually in effect. Report the SAME resolved values the recognizer
        // uses, via the shared resolvers. PII-safe: numbers/bools only.
        lines.append("[Effective (live, as used by the recognizer)]")
        lines.append("  matchThreshold:  \(resolvedMatchThreshold(for: descriptor))")
        // ND-076: per-model threshold provenance (numbers only).
        let range = descriptor.matchThresholdRange
        lines.append("  matchThreshold model default: \(descriptor.defaultMatchThreshold) (\(descriptor.thresholdIsTuned ? "tuned" : "not yet tuned"))")
        lines.append("  matchThreshold range:  \(range.lowerBound)...\(range.upperBound)")
        lines.append("  matchThreshold override (\(descriptor.thresholdOverrideKey)): \(thresholdOverrideDescription(descriptor))")
        lines.append("  antiSpoofEnabled: \(resolvedAntiSpoofEnabled())")
        lines.append("  spoofTextureFloor: \(resolvedSpoofTextureFloor(default: defaultSpoofTextureFloor))")
        lines.append("")

        // --- Trusted networks: COUNT only, never SSID strings ---
        lines.append("[Trusted networks]")
        lines.append("  Count: \(trustedNetworkCount)")
        lines.append("")

        // --- Recent app log tail (our subsystem only) ---
        lines.append("[Recent log — subsystem \(Log.subsystem)]")
        lines.append(recentLogTail())

        return lines.joined(separator: "\n")
    }

    /// Describe the stored per-model override: "none", its value, or its value flagged as
    /// rejected when the resolver would ignore it (out of range / non-numeric).
    private func thresholdOverrideDescription(_ descriptor: FaceEmbeddingModelDescriptor) -> String {
        guard let raw = UserDefaults.standard.object(forKey: descriptor.thresholdOverrideKey) else {
            return "none"
        }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            return "(non-numeric) — rejected: not a number"
        }
        let v = n.doubleValue
        return v.isFinite && descriptor.matchThresholdRange.contains(v)
            ? "\(v)"
            : "\(v) — rejected: out of range"
    }

    /// Copy the summary to the general pasteboard. Convenience wrapper around
    /// `diagnosticsSummary(...)` so the menu action is a one-liner.
    @discardableResult
    func copyToPasteboard(
        state: PresenceState,
        config: Config,
        descriptor: FaceEmbeddingModelDescriptor,
        store: EnrollmentStoring,
        identity: IdentityStatus,
        locationStatus: CLAuthorizationStatus,
        trustedNetworkCount: Int,
        notificationStatusDescription: String? = nil,
        lockCapability: LockCapability,
        cameraUnavailableReason: String? = nil,
        now: Date = Date()
    ) -> String {
        let summary = diagnosticsSummary(
            state: state,
            config: config,
            descriptor: descriptor,
            store: store,
            identity: identity,
            locationStatus: locationStatus,
            trustedNetworkCount: trustedNetworkCount,
            notificationStatusDescription: notificationStatusDescription,
            lockCapability: lockCapability,
            cameraUnavailableReason: cameraUnavailableReason,
            now: now
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        return summary
    }

    // MARK: - Status label helpers (labels only, no data)

    /// Lock self-test result (ND-058): "SACLockScreenImmediate, SACSwitchToLoginWindow"
    /// or "NONE". Also used by the app's launch/wake self-test log line.
    static func lockCapabilityDescription(_ capability: LockCapability) -> String {
        capability.canLock
            ? capability.available.map(\.symbolName).joined(separator: ", ")
            : "NONE"
    }

    /// Human-readable identity status (ND-073). Model version strings only — never
    /// embeddings or images. Also used by the app's identity-change log line.
    static func identityStatusDescription(_ status: IdentityStatus) -> String {
        switch status {
        case .active:      return "active"
        case .notEnrolled: return "not enrolled"
        case .unknown:     return "unknown (enrollment store unreadable / not yet checked)"
        case .off(.modelMismatch(let stored, let active)):
            return "OFF — model mismatch (enrolled with \(stored ?? "legacy/unversioned"), active \(active)); any face counts, re-enroll needed"
        case .off(.enrollmentMissing(let expected)):
            return "OFF — enrollment missing (marker says enrolled with \(expected)); any face counts, re-enroll needed"
        }
    }

    private func cameraStatusDescription() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:    return "authorized"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "not determined"
        @unknown default:    return "unknown"
        }
    }

    private func locationStatusDescription(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways:    return "authorized (always)"
        case .authorized:          return "authorized"
        case .denied:              return "denied"
        case .restricted:          return "restricted"
        case .notDetermined:       return "not determined"
        @unknown default:          return "unknown"
        }
    }

    private func presenceStateDescription(_ state: PresenceState) -> String {
        switch state {
        case .unknown:            return "unknown (starting)"
        case .present:            return "present"
        case .absent:             return "absent"
        case .paused:             return "paused"
        case .trustedNetwork:     return "trusted network (enforcement paused)"
        case .callAssumedPresent: return "call — assumed present"
        case .suspended:          return "suspended (locked / asleep)"
        case .cameraUnavailable:  return "camera unavailable"
        case .lockFailed:         return "lock failed"
        }
    }

    // MARK: - Log tail

    /// Tail recent entries from the unified log for THIS process, filtered to our
    /// subsystem. Degrades to a clear placeholder if OSLogStore is unavailable or
    /// throws (it can be entitlement/permission-sensitive, and is unavailable in
    /// some sandboxes). Never includes anything but our own log messages, which
    /// are authored to be PII-free.
    private func recentLogTail(maxEntries: Int = 100, window: TimeInterval = 300) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-window))
            let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
            let entries = try store.getEntries(at: start, matching: predicate)

            // Hoist a single formatter out of the loop: allocating a DateFormatter per
            // entry (up to `maxEntries` ~100) is needlessly expensive.
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"

            var formatted: [String] = []
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                let ts = timeFormatter.string(from: logEntry.date)
                formatted.append("  \(ts) [\(logEntry.category)] \(logEntry.composedMessage)")
            }
            guard !formatted.isEmpty else {
                return "  (no recent log entries)"
            }
            // Keep only the most recent `maxEntries`.
            let tail = formatted.suffix(maxEntries)
            return tail.joined(separator: "\n")
        } catch {
            return "  (logs unavailable)"
        }
    }

    // MARK: - Formatting

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
