import Foundation
import IOKit

// Owner: homer — lid (clamshell) state, consumed by the bounded camera-unavailable
// policy (ND-078). AppKit-free so it lives in NoDonutsCore.

/// Lid (clamshell) state from the power-management root domain (`IOPMrootDomain`,
/// property `AppleClamshellState`).
///
/// The bounded camera-unavailable window (ND-078) escalates to a lock ONLY when
/// `.open`: a laptop with its lid open, where the built-in camera should be there.
/// `.closed` (clamshell) and `.noLid` (desktop Mac — mini/Studio/Pro — which has no
/// built-in camera, so under ADR-0015 it is permanently unavailable) never escalate.
public enum LidState: Equatable, Sendable {
    case open
    case closed
    /// No `AppleClamshellState` property at all → a Mac without a lid (desktop).
    case noLid

    /// Current lid state.
    /// - property absent → `.noLid`
    /// - property `true` → `.closed`; `false` → `.open`
    /// - property present but not a Bool, or the root domain can't be found →
    ///   `.open` (fail-safe: keeps the bounded window armed, so a misread can
    ///   only cause an unneeded lock, never an indefinite fail-open).
    public static func current() -> LidState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return .open }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return .noLid }
        guard let closed = value as? Bool else { return .open }
        return closed ? .closed : .open
    }

    /// Convenience: `true` only for a positively-closed lid. Prefer `current()`
    /// (a desktop reports `false` here but never escalates — it is `.noLid`).
    public static func isClosed() -> Bool { current() == .closed }
}
