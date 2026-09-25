# ADR-0015 — Camera trust: use the built-in camera only

- Status: Accepted
- Date: 2026-09-25
- Owner: blart (with wiggum)

## Context

`CameraController` captured from `AVCaptureDevice.default(for: .video)`, which is whatever camera macOS picks. That includes **virtual cameras**: OBS, Snap Camera, and any CMIO camera extension. They feed arbitrary video. A looped clip of the enrolled user would match every tick and keep the Mac unlocked indefinitely. That is a trivial, repeatable spoof, much stronger than the flat-photo case EC-12 addresses. Virtual cameras usually present as device type `.external`, the same as physical USB webcams. The reliable difference is their transport type.

The app is meant for internal distribution to colleagues on essentially the same laptop hardware (ND-111), all of which have a built-in camera.

## Decision

**Trust only the Mac's built-in camera.**

- Select the device through `AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], …)`, and require **both** the built-in device type **and** a built-in transport (`transportType == kIOAudioDeviceTransportTypeBuiltIn`). Requiring both is defense in depth: a virtual device claiming a built-in type is still rejected. The pure rule lives in `CameraTrustPolicy` and is covered by EngineCheck.
- External USB webcams, iPhone Continuity Camera and virtual cameras are **never used**. They are logged once as "ignored untrusted camera".
- If no trusted camera is present, `capture()` returns `.unavailable("no trusted built-in camera …")`. The app shows the honest "camera unavailable" state with that reason, plus the existing not-protecting notification (EC-07/08/09 policy). It never falls back to an untrusted device.
- The busy probe and the wedged in-use check query the same trusted device, not `.default` (discharges ND-066b).

## Consequences

- A virtual-camera replay can no longer drive identity. A physical attacker would need to present a spoof to the real lens, which ND-041/ND-072 anti-spoofing covers.
- **Clamshell with an external webcam is unprotected.** With the lid closed there is no built-in camera, so the app reports "camera unavailable" and doesn't lock (EC-07). This is accepted for a laptop fleet. It can be revisited, for example with an allowlist of physical USB transports, if a colleague needs it.
- ND-096's "follow `systemPreferredCamera`" becomes moot: the preferred camera is never followed.

## Alternatives considered

- **Built-in + physical USB + Continuity; reject only virtual transports.** Broader hardware support, but it relies on third-party drivers reporting their transport honestly, and it trusts an iPhone stream. It was the recommended option in the interview; the user chose the strict one.
- **Keep `.default` and detect virtual cameras by name or manufacturer.** Brittle and trivially evaded. Rejected.
