import Foundation

// Owner: cooper (with wiggum's security hat). Basic anti-spoofing / liveness.
// Backlog: ND-041. Edge case: EC-12. Privacy: pure computation on in-memory
// luminance samples; no image or embedding is stored or transmitted, no network.

// MARK: - Threat model & rationale (wiggum)
//
// A printed photo, or a face shown on a phone/monitor, held up to the camera tends
// to have LOWER high-frequency texture detail and flatter micro-contrast than a live
// face at the same crop size: paper/print halftoning and screen reproduction lose
// fine skin/pore/eyelash detail, add blur, and (for screens) low-pass the image.
//
// We exploit that with a single, cheap, CONSERVATIVE signal: the variance of a
// discrete-Laplacian high-pass over the face crop's luminance ("focus"/sharpness
// metric). A live face crop has meaningful high-frequency energy; a clearly
// degraded/flat reproduction has very little.
//
// CONSERVATIVE bias (non-negotiable, EC-12): we only ever FLAG a spoof when the
// texture score is below a VERY LOW floor — i.e. the crop is unambiguously flat.
// When in doubt we treat the input as LIVE and do NOT flag. The cost of a false
// spoof flag is a false lock of the real user (unacceptable); the cost of a missed
// spoof is that a high-quality photo passes (acceptable for a v1 that is explicitly
// NOT hardened). This check is defeatable by a sharp, high-resolution photo or a
// high-DPI screen at the right size — it is a speed-bump, not a guarantee. See EC-12.

/// Default texture floor below which a face crop is treated as a likely spoof.
///
/// Deliberately VERY LOW: this is the variance of an 8-bit-luminance Laplacian
/// response (units are luminance² in `[0, 255]` space). A normally-lit live face
/// crop produces scores in the hundreds-to-thousands range; a flat print/screen
/// reproduction collapses toward single/low-double digits. A floor of `12.0` sits
/// well under any plausible live face while still catching clearly flat inputs.
///
/// This value is a defensible STARTING POINT and MUST be tuned on real on-device
/// data (lighting, camera, crop size all shift the absolute scale). It — and the
/// whole check — is user-toggleable via the `antiSpoofEnabled` default (Settings).
/// Bias tuning ALWAYS toward a lower floor: never risk flagging a live face.
public let defaultSpoofTextureFloor: Double = 12.0

/// Resolve whether anti-spoofing is enabled, from `UserDefaults`.
///
/// Defaults to **true** (ND-041 decision: anti-spoof ON by default, conservative).
/// Absent key → enabled. Only an explicit stored `false` disables it. Mirrors the
/// other resolvers in this module: a single cheap `UserDefaults` read, safe per call.
public func resolvedAntiSpoofEnabled(
    defaults: UserDefaults = .standard,
    key: String = "antiSpoofEnabled"
) -> Bool {
    // Absent → default ON. `object(forKey:)` distinguishes "absent" from a stored
    // `false`, so we don't accidentally disable when the key was never written.
    guard defaults.object(forKey: key) != nil else { return true }
    return defaults.bool(forKey: key)
}

/// Resolve the spoof texture **floor** for the liveness check, from `UserDefaults`.
///
/// Mirrors `resolvedMatchThreshold` / `resolvedVisionOrientation` / `resolvedAntiSpoofEnabled`:
/// a pure, testable resolver that reads a single `UserDefaults` value and falls back
/// to a safe `def` (typically `defaultSpoofTextureFloor` = 12.0) when the stored value
/// is absent or nonsensical. The recognizer calls this PER CALL so the floor is tunable
/// live (no relaunch) via `defaults write com.nodonuts.app spoofTextureFloor <n>`.
///
/// Validation — an override is accepted ONLY if it is a **finite, strictly-positive**
/// number:
/// - Absent / non-numeric → `def` (safe default).
/// - `0`, negative, NaN, ±infinity → `def`. A floor of `0` or below could never flag
///   anything anyway (scores are `>= 0`); we normalize such junk back to the tuned
///   default rather than silently disable the whole check via a malformed value.
///
/// To effectively DISABLE the check without the toggle, set a very LOW positive floor
/// (e.g. `defaults write com.nodonuts.app spoofTextureFloor 0.0001`): a valid tiny
/// positive value is accepted, and no real crop scores below it, so nothing is flagged.
/// (Setting `0` or negative is rejected → default, so a *tiny positive* is the escape
/// hatch, on purpose — it keeps the "reject fail-open junk" rule intact.)
///
/// Cheap (a single `UserDefaults` read); safe to call per recognition pass.
public func resolvedSpoofTextureFloor(
    default def: Double = defaultSpoofTextureFloor,
    defaults: UserDefaults = .standard,
    key: String = "spoofTextureFloor"
) -> Double {
    // `object(forKey:)` distinguishes "absent" from a stored 0, and lets us reject
    // non-numeric junk (a stored String, etc.) rather than coercing it to 0.
    guard let value = defaults.object(forKey: key) as? NSNumber else { return def }
    let floor = value.doubleValue
    // Accept only a finite, strictly-positive floor; else fall back to the safe default.
    guard floor.isFinite, floor > 0.0 else { return def }
    return floor
}

/// Compute a texture / sharpness score for a face crop from its luminance samples.
///
/// Pure and testable: takes a row-major buffer of 8-bit luminance values (`0...255`
/// as `Double`) plus its `width`/`height`, and returns the variance of a discrete
/// Laplacian (`4·center − up − down − left − right`) over all interior pixels. This
/// is the classic "variance of Laplacian" focus/detail metric — higher means more
/// high-frequency texture (a live, in-focus face); near-zero means flat/blurred
/// (a degraded photo or screen reproduction).
///
/// Defensive: returns `0` (which, being below any sane floor, biases toward a spoof
/// flag ONLY under conservative gating — see how the recognizer never flags on the
/// not-enrolled path and only on a genuine match) when the input is too small or
/// malformed. Non-finite samples are treated as `0` contribution. The caller decides
/// what a `0` means via `isLikelySpoof`; on a real crop this function never returns 0.
public func faceTextureScore(luminance: [Double], width: Int, height: Int) -> Double {
    // Need at least a 3x3 so there is one interior pixel with all four neighbors.
    guard width >= 3, height >= 3, luminance.count == width * height else { return 0 }

    var sum = 0.0
    var sumSq = 0.0
    var n = 0

    // Interior pixels only (skip the 1-px border so every neighbor exists).
    for y in 1..<(height - 1) {
        let row = y * width
        let up = row - width
        let down = row + width
        for x in 1..<(width - 1) {
            let c = luminance[row + x]
            let l = luminance[row + x - 1]
            let r = luminance[row + x + 1]
            let u = luminance[up + x]
            let d = luminance[down + x]
            let lap = 4.0 * c - l - r - u - d
            guard lap.isFinite else { continue }
            sum += lap
            sumSq += lap * lap
            n += 1
        }
    }

    guard n > 0 else { return 0 }
    let mean = sum / Double(n)
    let variance = sumSq / Double(n) - mean * mean
    // Numerical floor: variance is non-negative by definition; clamp tiny negatives
    // from float error to 0.
    return variance.isFinite && variance > 0 ? variance : 0
}

/// Decide whether a texture score indicates a likely spoof (flat photo / screen).
///
/// Pure, total, and the SINGLE place the conservative bias lives: a crop is flagged
/// ONLY when its `textureScore` is STRICTLY below `floor`. A score exactly at or
/// above the floor is treated as LIVE (not flagged). Callers gate this further
/// (enrolled + matching only) so a live face is never false-locked (EC-12).
public func isLikelySpoof(textureScore: Double, floor: Double = defaultSpoofTextureFloor) -> Bool {
    // Strictly-below → flag. `>=` (incl. exactly-at-floor) → live. Non-finite floor
    // is treated as "no floor" (never flag) to fail toward LIVE.
    guard floor.isFinite else { return false }
    return textureScore < floor
}
