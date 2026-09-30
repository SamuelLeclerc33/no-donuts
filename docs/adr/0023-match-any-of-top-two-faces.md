# ADR-0023 — Match any of the top two faces; liveness tracks each face

- Status: Accepted
- Date: 2026-09-29
- Owner: cooper (with homer, krusty)

## Context

Recognition embedded only the **largest** face in the frame. When a colleague leaned in closer to the camera than the enrolled user, their face became the largest, scored as a stranger, and the ADR-0017 fast path locked the Mac in about 3 s while the user sat in front of it (EC-06, ND-059).

Liveness (ADR-0022) had the same limit: it tracked only the largest face. Matching a smaller face alone would not help, because the user's own blinks would land on the colleague's track and the match would read as not live.

## Decision

- **Lazy top-two matching.** Embed the largest face. Only if it does not clear the threshold, embed the second largest. Report present if either matches. Report `.strangerOnly` only when neither does. A third face is never considered. The ND-085 quality gate applies to each face, and the texture check runs on the face that matched.
- **Identity, then confirmation.** With "Reject photos of me" on, a face that matches must also be confirmed: its texture is not a likely flat spoof and its liveness verdict is live. If the largest face matches but is not confirmed (a poster or phone photo of the user), the second face is tried. It counts only if it matches and is confirmed. Otherwise the largest face is returned and rejected exactly as before: flat means stranger, not live means `.notLive`. The recognizer re-checks texture and liveness on the face it gets back, so a bug in the selection can pick a face but never unlock. Texture is scored at most twice per tick.
- The embedder takes a match predicate (`FaceSelection`) from the recognizer, so detection runs once and the threshold stays in the recognizer. Presence-only paths (not enrolled, model mismatch) stay largest-only.
- A glitch never turns into a stranger reading. If the largest face fails to embed and the second does not match, the result is `.error` (EC-10). The same holds the other way round: the largest face does not match and the second fails to embed → `.error`, since the second face may be the user. If the largest face matched but was not confirmed and the second fails, the largest face's rejection stands (fail closed).
- The recognizer decides from the selection's own scored evaluation (the report carries the match score), so the threshold used to pick a face and the one used to decide are the same by construction.
- **Liveness keeps up to two face tracks.** Each track has its own blink and motion detectors. The verdict uses only the track of the face that matched (the ND-116 rule). The matched box binds to a track only when that track is decisively the closest one (by an IoU margin of 0.3). A second track or an untracked face nearly as close leaves the verdict unbound (not live).
- **Uncertain assignments reset, overlaps don't.** Two faces that overlap steadily each keep their own track when the assignment is clear: the best face-to-track assignment beats every conflicting one by the 0.3 margin. Only an uncertain assignment ends the tracks involved, with no handoff: faces crossing, nearly on top of each other, or a face landing between two tracks. Evidence can't move from a live face onto a photo by crossing it.
- **Faces without landmarks still count.** A top-two face whose landmarks are missing or unusable gets no track and no evidence. It is still recorded as an occupant. A matched box that is closer to an occupant than decisively to a track is unbound. This way a photo whose landmarks failed, held partly over a live attacker's face, can't borrow the attacker's evidence.
- **Duplicate detections merge.** Two detections with IoU ≥ 0.7, the same scale (IOD within 10%) and both eye centres within 0.1 IOD are one face reported twice. They merge into one track, unless two different nearby tracks are close to the pair (two faces meeting). The tracker never holds more than two tracks.
- **Enrollment needs one face.** A frame with more than one face that passes the quality gate adds no vector, so a photobomber can't get enrolled.
- User and stranger both in frame, user matches → present. Shoulder-surfing stays out of scope (EC-06).

## Consequences

- A colleague leaning in no longer locks the user out.
- **False-accept surface grows in frames with two non-user faces:** per tick it becomes about `1 − (1 − p)²` instead of `p`. Lazy evaluation adds nothing when the largest face is the user. This ships **before** the ND-056 threshold study by the owner's choice, and ND-056 must choose the threshold against the top-two rate (FaceScore prints it).
- **A stranger holding a photo of the user locks more slowly:** the photo matches as face two, has no live evidence, and reads `.notLive`. That goes through the normal absence path (about 10 s) instead of the ADR-0017 fast path (about 3 s). It still locks. Accepted by the owner.
- A user whose face crosses a colleague's loses their liveness evidence and needs a fresh blink or movement. If none comes before consensus plus grace, the normal absence path locks.
- A user whose head a colleague's steadily overlaps keeps their track and evidence. Only faces nearly on top of each other reset, so the user needs a fresh blink or movement then. A lapse goes through the ~10 s absence path, never the 3 s fast lock.
- A poster or phone photo of the user that is larger than the live user no longer locks them out. The live user is tried as the second face and counts if confirmed.
- Known hole, not widened: hiding the face for under 1 s and putting a photo in the same spot at a similar size (≤ 25% size change) continues the same track. The one-track design had the same hole. With two faces it includes a live stranger and a photo of the user **trading places** between two analyzed frames (or while the camera is covered for under 1 s). The boxes are then the same as two faces standing still, so no box rule can tell them apart without also resetting a user who sits beside a colleague. This was already open for faces side by side (IoU 0). An earlier draft reset every overlap of IoU ≥ 0.2, which only closed the overlapping variant and false-locked a present user beside a colleague. Closing the hole needs an identity signal per track (for example landmark-shape continuity), which is future work.
- Cost: at most one extra embedding per tick, and only when the largest face does not match. Landmarks were already computed for every face, so liveness adds only per-track arithmetic.
- Amends ADR-0017 (the "multi-face matching" mitigation is now in place) and ADR-0022 (liveness no longer tracks the largest face only).

## Alternatives considered

- **Always embed both faces.** Simpler, but about twice the Core ML cost whenever two faces are visible, and no benefit when the user is the largest face.
- **Top three.** More coverage for crowded desks, but a larger false-accept surface before the threshold is tuned.
- **Liveness follows the matched face** (switch its single track to whichever box matched). Simpler, but every switch resets evidence and opens startup-window gaps.
- **Treat a matched but not live face beside a stranger as a stranger (3 s).** Keeps the fast lock for the photo attack, but would false-lock the user in about 3 s whenever their track briefly lacked evidence with a colleague in frame.
