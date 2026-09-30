import Foundation
import CoreGraphics
import CoreImage

// Owner: cooper — face quality gate + undistorted square crop (ND-085).
// Privacy: pure geometry + in-memory Core Image composition; no I/O, no network.

/// Minimum face size, as a fraction of the frame's SHORTER side, that the embedders
/// will embed (ND-085). A smaller largest face is reported as `.noFace`.
///
/// Why 12%: a typical Mac webcam has a ~40° vertical field of view in landscape. A
/// Vision face box (brow to chin, ~18 cm) fills 12% of the frame height at about
/// 2 m from the camera. At a normal seated distance (40–80 cm) the box is 25–60%. At
/// 720p, 12% is about 86 px, which the FaceNet path scales up ~1.9x to 160 px. Smaller
/// faces are mostly interpolation, so the embedding scores badly for the real user
/// (false-reject) and is less discriminative for strangers (false-accept).
///
/// Why `.noFace` and not a stranger: a person 2 m or more away is not at the keyboard.
/// `.noFace` counts toward absence, which is what "away" should do. A stranger result
/// would speed up locking on a distant face that may be the real user walking by.
/// Returning present would let a distant face keep the Mac unlocked.
///
/// The frame's shorter side is used (not its height) so the gate reads the same under
/// a `visionOrientation` override that rotates the frame to portrait.
public let minimumFaceSideFraction: CGFloat = 0.12

/// True when the face's shorter side is at least `minimumFraction` of the frame's
/// shorter side (ND-085). `faceBoundingBox` is Vision-normalized (0…1) in the ORIENTED
/// space; `orientedExtent` is that space's pixel extent. A degenerate extent or box
/// is reported as too small (fail toward `.noFace`, never toward a match).
public func faceIsLargeEnough(
    faceBoundingBox bb: CGRect,
    orientedExtent: CGRect,
    minimumFraction: CGFloat = minimumFaceSideFraction
) -> Bool {
    let frameShort = min(orientedExtent.width, orientedExtent.height)
    guard frameShort > 0, frameShort.isFinite,
          bb.width.isFinite, bb.height.isFinite else { return false }
    let faceShort = min(bb.width * orientedExtent.width, bb.height * orientedExtent.height)
    guard faceShort > 0 else { return false }
    return faceShort >= minimumFraction * frameShort
}

/// Geometry of an undistorted square face crop (ND-085), in the ORIENTED image's pixel
/// space (bottom-left origin, same as Core Image).
public struct SquareFaceCrop: Equatable, Sendable {
    /// The full square: centered on the face, side = the longer padded face side. It
    /// may extend past the frame. Scaling this uniformly to the model's input size never
    /// distorts the face.
    public let square: CGRect
    /// `square` intersected with the frame: the pixels that really exist. The rest of
    /// the square is filled with black (`needsPadding`).
    public let visible: CGRect
    /// True when part of the square lies outside the frame and will be black-padded.
    public var needsPadding: Bool { visible != square }
}

/// Square crop around a Vision face box (ND-085). This replaces the old approach,
/// which clipped the padded box at the frame edge and then stretched the clipped
/// rectangle to 160×160 on each axis separately. That stretch distorted faces near the
/// frame edge and produced bad embeddings.
///
/// Steps: pad the face box by `paddingFraction` of its size on each side (in pixels),
/// take the longer padded side as the square side, center the square on the face
/// center, and snap it to whole pixels. `visible` is the part inside the frame.
///
/// Returns `nil` for a degenerate box or extent, or when the square misses the frame
/// entirely. Callers map `nil` to `.failure` (EC-10), never to "no face".
public func squareFaceCrop(
    faceBoundingBox bb: CGRect,
    paddingFraction: CGFloat,
    orientedExtent: CGRect
) -> SquareFaceCrop? {
    let w = orientedExtent.width, h = orientedExtent.height
    guard w > 0, h > 0, w.isFinite, h.isFinite,
          bb.width > 0, bb.height > 0, bb.origin.x.isFinite, bb.origin.y.isFinite,
          bb.width.isFinite, bb.height.isFinite,
          paddingFraction >= 0, paddingFraction.isFinite else { return nil }

    let faceW = bb.width * w
    let faceH = bb.height * h
    let side = (max(faceW, faceH) * (1 + 2 * paddingFraction)).rounded()
    guard side >= 1 else { return nil }
    let cx = orientedExtent.origin.x + (bb.midX * w)
    let cy = orientedExtent.origin.y + (bb.midY * h)
    let square = CGRect(x: (cx - side / 2).rounded(), y: (cy - side / 2).rounded(),
                        width: side, height: side)
    let visible = square.intersection(orientedExtent)
    guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
    return SquareFaceCrop(square: square, visible: visible)
}

/// Build the square model input for `crop` from the oriented frame image (ND-085).
/// The visible pixels are placed over a black square, then translated to the origin
/// and scaled UNIFORMLY to `side`×`side`. Render the result into a `side`×`side`
/// buffer.
///
/// Why black and not edge-clamp: clamping repeats the edge pixels into streaks that
/// look like hair or background texture to the model. A flat black border adds no
/// fake structure. It is the usual border for aligned face crops.
public func squareFaceInputImage(from orientedImage: CIImage, crop: SquareFaceCrop, side: Int) -> CIImage {
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: crop.square)
    let composed = orientedImage.cropped(to: crop.visible).composited(over: black)
    let scale = CGFloat(side) / crop.square.width
    return composed
        .transformed(by: CGAffineTransform(translationX: -crop.square.origin.x, y: -crop.square.origin.y))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
}

/// Indices (into `boxes`) of the faces an embedder may embed, largest first (ND-059).
///
/// Order matters for security: the top `maxFaces` (clamped to `1...2`) are taken by
/// bounding-box AREA first, THEN each is checked against the ND-085 quality gate
/// (`faceIsLargeEnough`). A tiny third face is never promoted into the top two because
/// a bigger face happened to fail the gate. Ties in area keep the lower index (the same
/// face `max(by:)` picked before ND-059), so the order is deterministic. A non-finite
/// box sorts last and fails the gate.
///
/// With `maxFaces == 1` this is exactly the pre-ND-059 rule: the largest face, or none
/// if it is too small.
public func rankedFaceCandidates(boxes: [CGRect], orientedExtent: CGRect, maxFaces: Int) -> [Int] {
    let top = faceIndicesByArea(boxes).prefix(clampedCandidateFaces(maxFaces))
    return top.filter { faceIsLargeEnough(faceBoundingBox: boxes[$0], orientedExtent: orientedExtent) }
}

/// Most faces any path considers per frame (ND-059): the recognizer's top-N, the liveness
/// analyzer's tracks, and `FaceSelection.maxFaces` all clamp to this ONE constant, so
/// the recognizer and liveness can never disagree on how many faces take part.
public let maxCandidateFaces = 2

/// `n` clamped to `1...maxCandidateFaces`.
public func clampedCandidateFaces(_ n: Int) -> Int { min(max(n, 1), maxCandidateFaces) }

/// Indices of `boxes`, largest area first; equal areas keep the lower index; a
/// non-finite area sorts last. The ONE ordering shared by `rankedFaceCandidates` and
/// `FaceTracker` (ND-059).
public func faceIndicesByArea(_ boxes: [CGRect]) -> [Int] {
    func area(_ b: CGRect) -> CGFloat {
        let a = b.width * b.height
        return a.isFinite ? a : -.infinity
    }
    return boxes.indices.sorted {
        area(boxes[$0]) != area(boxes[$1]) ? area(boxes[$0]) > area(boxes[$1]) : $0 < $1
    }
}
