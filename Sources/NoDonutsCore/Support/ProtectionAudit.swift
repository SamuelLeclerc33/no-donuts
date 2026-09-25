import Foundation

// Owner: krusty (with wiggum's security hat). Tamper-visible tunables (ND-077).
//
// The security tunables (identity match threshold, anti-spoof toggle, spoof texture
// floor) are live `UserDefaults` values, so `defaults write com.nodonuts.app …` (or the
// Settings window) can weaken identity checking with no other trace. This audit turns
// "weaker than the shipped default" into human-readable reasons the menu header and the
// diagnostics report surface, so reduced protection is never silent.
//
// It reads the SAME resolvers the recognizer uses, so it reports the values actually in
// effect: an override the resolver rejects (e.g. an out-of-range threshold) falls back to
// the default and is correctly NOT flagged. Stricter-than-default is never "reduced".

/// Human-readable reasons protection is weaker than the shipped defaults, or `[]` when
/// every security tunable is at (or stricter than) its default.
///
/// - Effective match threshold (`resolvedMatchThreshold(for:)`) below
///   `descriptor.defaultMatchThreshold` → identity accepts looser matches.
/// - `resolvedAntiSpoofEnabled() == false` → photo/screen spoof check off.
/// - `resolvedSpoofTextureFloor()` below `defaultSpoofTextureFloor` → the spoof check
///   flags less (a tiny positive floor effectively disables it).
///
/// Pure apart from the injected `defaults` read; no side effects.
public func reducedProtectionReasons(
    descriptor: FaceEmbeddingModelDescriptor,
    defaults: UserDefaults = .standard
) -> [String] {
    var reasons: [String] = []

    let threshold = resolvedMatchThreshold(for: descriptor, defaults: defaults)
    if threshold < descriptor.defaultMatchThreshold {
        reasons.append("match threshold lowered (\(format(threshold)) < default \(format(descriptor.defaultMatchThreshold)))")
    }

    let antiSpoofOn = resolvedAntiSpoofEnabled(defaults: defaults)
    if !antiSpoofOn {
        reasons.append("anti-spoof off")
    }

    // Only meaningful while anti-spoof is on; when it's off that reason already covers it.
    let floor = resolvedSpoofTextureFloor(default: defaultSpoofTextureFloor, defaults: defaults)
    if antiSpoofOn, floor < defaultSpoofTextureFloor {
        reasons.append("anti-spoof floor lowered (\(format(floor)) < default \(format(defaultSpoofTextureFloor)))")
    }

    return reasons
}

/// Compact number formatting for the menu (e.g. 0.35, 12, 0.0001).
private func format(_ value: Double) -> String {
    let s = String(format: "%.4f", value)
    var trimmed = s
    while trimmed.hasSuffix("0") { trimmed.removeLast() }
    if trimmed.hasSuffix(".") { trimmed.removeLast() }
    return trimmed
}
