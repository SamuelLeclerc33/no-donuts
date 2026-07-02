import Foundation

/// Shared logging identifiers for No Donuts (ND-044).
///
/// Use this namespace when constructing NEW loggers so every subsystem/category
/// string comes from one place:
///
///     let log = Logger(subsystem: Log.subsystem, category: Log.Category.presence)
///     let oslog = OSLog(subsystem: Log.subsystem, category: Log.Category.recognition)
///
/// This also lets the diagnostics reporter (`DiagnosticsReporter`) filter the
/// unified log to exactly our subsystem when it tails recent app logs.
///
/// NOTE: existing code that hardcodes `"com.nodonuts.app"` (notably
/// `CameraController.swift`, `EnrollmentStore.swift`, and the matchThreshold
/// logger in `main.swift`) is a tracked follow-up and is intentionally NOT
/// rewritten here — the subsystem value is identical, so old and new loggers
/// still land under the same subsystem and are picked up by diagnostics.
///
/// Privacy: these are static identifiers only — no user data, ever.
public enum Log {
    /// The unified-logging subsystem for every No Donuts logger. Must match the
    /// hardcoded string used by the existing loggers so diagnostics captures all
    /// of them.
    public static let subsystem = "com.nodonuts.app"

    /// Per-module log categories. Keep these aligned with the module owners so a
    /// `log stream --predicate 'subsystem == "com.nodonuts.app"'` reads cleanly.
    public enum Category {
        /// Presence state machine, grace timers, decision policy (homer).
        public static let presence = "presence"
        /// Face detection, embeddings, matching, enrollment (cooper).
        public static let recognition = "recognition"
        /// Camera capture + camera-in-use monitoring (blart).
        public static let camera = "camera"
        /// Screen locking + fail-safe enforcement (wiggum).
        public static let lock = "lock"
        /// Login session / lock-screen / wake monitoring.
        public static let session = "session"
        /// App shell, menu bar, settings, diagnostics (krusty / gordon).
        public static let app = "app"
    }
}
