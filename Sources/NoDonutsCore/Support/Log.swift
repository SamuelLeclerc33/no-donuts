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
/// Every logger in the code base uses `Log.subsystem` (ND-065); the value itself
/// comes from `AppIdentity.logSubsystem`, so there is no second copy of the string.
///
/// Privacy: these are static identifiers only — no user data, ever.
public enum Log {
    /// The unified-logging subsystem for every No Donuts logger (= the bundle id,
    /// `AppIdentity.logSubsystem`). Diagnostics filters the unified log on it.
    public static let subsystem = AppIdentity.logSubsystem

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
