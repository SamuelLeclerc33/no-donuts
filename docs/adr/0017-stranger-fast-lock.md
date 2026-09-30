# ADR-0017 — Stranger at the keyboard locks fast (3 ticks, no grace)

- Status: Accepted
- Date: 2026-09-28
- Owner: homer (with cooper)

## Context

A sustained `.strangerOnly` reading means a face is at the keyboard and it is not the enrolled user, or it was flagged as a spoof. It used to get the same absence consensus (5 ticks) and grace (5 s) as an empty desk: about 10 s of access. Grace exists so the enrolled user can turn their head or glance away without being locked. It was never meant to hand a stranger 10 seconds at an unlocked Mac, and this is the highest-threat state the app can observe.

## Decision

- **3 consecutive stranger ticks (~3 s at the 1 s tick) → lock with no grace** (`consecutiveStrangerTicksToLock = 3`, `strangerGraceSeconds = 0`).
- The stranger streak is reset by a no-face tick or a present tick. A recognition error holds it (EC-10), neither advancing nor resetting.
- Stranger ticks **also** count toward the normal absence consensus, so alternating stranger and no-face readings still lock on the normal ~10 s path.
- The fast lock uses the same lock path as normal absence: ND-054 retry and backoff, the ND-079 in-flight guard, and the episode-generation guard.
- Only applies once enrolled. Before enrollment, any face counts as present.

## Consequences

- A stranger gets about 3 s instead of about 10 s.
- **False-lock risk rises for the enrolled user** if they are misread as a stranger three times in a row (bad lighting, extreme angle, an untuned threshold). Mitigations: ND-085 face quality gate, ND-063 enrollment consistency, and the threshold study ND-056. Multi-face matching (ND-059) will stop a colleague leaning in from counting as a stranger while the user is also in frame.
- The unlock is a normal macOS unlock, so a false lock is an annoyance, not data loss.

## Alternatives considered

- **3 ticks + 2 s grace (~5 s).** More tolerant of misreads. Rejected: the threat state deserves the shortest window, and the misread risk is addressed at the recognition layer.
- **Keep ~10 s.** Rejected as giving strangers the grace meant for the user.

## Amendment 2026-09-29 (ADR-0023)

Multi-face matching (ND-059) is in place: the second-largest face is tried when the largest doesn't match, so a colleague leaning in no longer counts as a stranger while the user is in frame. A stranger holding a photo of the user now takes the normal absence path (~10 s, `.notLive`) instead of this fast path.
