# Deployment — internal / MDM

Practical notes for putting No Donuts on colleagues' Macs, by hand or through the company's MDM (ND-053). Audience: whoever does the rollout, and the IT/security people who have to approve it.

!!! warning "Status (2026-09-28): not deployable to colleagues yet"
    Today's builds are **ad-hoc** or **self-signed "No Donuts Dev"** (`scripts/make-app.sh`, [ADR-0008](adr/0008-app-packaging.md)). They have **no Team ID** and are **not notarized**. Gatekeeper blocks them on any other Mac, MDM can't install them as a signed package, and the rules below that key on a Team ID can't be written yet.

    Blocking items: **ND-111** (distribution decision: channel, signing identity, IT and privacy sign-off; deferred), **ND-050** (Developer ID signing + notarization), **ND-051** (DMG). This page describes the target setup so IT can review it ahead of time.

!!! note "Templates"
    Every payload on this page is a **template to verify with IT** against your MDM vendor's schema and Apple's current [device-management reference](https://developer.apple.com/documentation/devicemanagement). Replace `TEAMID1234` with the real Team ID from ND-050, and generate fresh `PayloadUUID`s (`uuidgen`). None of these payloads have been tested on a managed Mac yet.

## What gets installed

| Item | Where | Notes |
|---|---|---|
| The app | `/Applications/NoDonuts.app` | Menu-bar only (`LSUIElement`), no Dock icon. macOS 15+. |
| Launcher | Inside the app: `Contents/Library/LaunchAgents/com.nodonuts.app.agent.plist` | Registered with `SMAppService` when the user turns on **Settings › Start at login** ([ADR-0018](adr/0018-bundled-keepalive-agent.md)). Nothing is written to `~/Library/LaunchAgents`. KeepAlive: a crash or kill relaunches it; a confirmed Quit stays quit. |
| Enrollment | Login Keychain, generic password, service `com.nodonuts.app`, account `enrollment` | Face **embeddings** only, never images ([SECURITY_PRIVACY](SECURITY_PRIVACY.md)). |
| Settings | `defaults` domain `com.nodonuts.app` | Thresholds, trusted Wi-Fi, etc. |
| Lock file | `~/Library/Application Support/NoDonuts/instance.lock` | Single-instance guard (ND-083). |

Everything is per user. The app never needs admin rights to run, uses no kernel or system extension, and needs no Accessibility permission ([ADR-0010](adr/0010-screen-lock-no-accessibility.md)).

## Supported hardware

- **MacBooks with a built-in camera** (the company fleet profile, ND-111(e)), macOS 15 or later.
- **Desktops (Mac mini, Mac Studio, Mac Pro) and clamshell use with an external webcam are unsupported.** The app trusts only the built-in camera ([ADR-0015](adr/0015-camera-trust-built-in-only.md)). External USB webcams, iPhone Continuity Camera and virtual cameras are ignored on purpose (anti-spoofing). With no built-in camera the app reports "camera unavailable" and **does not lock** (EC-07). Don't deploy it where it can't protect anything.
- An iMac has a built-in camera but isn't part of the validated fleet profile.

## Install

### Option A: signed, notarized DMG (small groups, unmanaged Macs)

1. Share the notarized `NoDonuts.dmg` (ND-051) through the usual internal channel.
2. The user drags `NoDonuts.app` to `/Applications` and opens it.
3. On first run: allow **Camera**, enroll, then turn on **Settings › Start at login**. If macOS asks, approve No Donuts in System Settings › General › Login Items.
4. Allow **Notifications** when asked. This matters (see [Notifications](#notifications)).

### Option B: MDM package (managed Macs)

Build a signed flat package that installs the app to `/Applications`, notarize it, and hand it to the MDM:

```sh
# Template: identities and profile names come from ND-050.
productbuild --component build/NoDonuts.app /Applications \
    --sign "Developer ID Installer: <Company> (TEAMID1234)" \
    NoDonuts-<version>.pkg
xcrun notarytool submit NoDonuts-<version>.pkg --keychain-profile "<profile>" --wait
xcrun stapler staple NoDonuts-<version>.pkg
```

Then push these profiles **before** or **with** the package, so nothing prompts that doesn't have to:

1. [Managed login item](#managed-login-item-service-management) (no "Background item added" approval).
2. [Notification settings](#notifications) (alerts on, so the safety alarms can reach the user).
3. No PPPC profile is needed. See [Camera](#camera-pppc-cant-pre-grant-it).

Even with MDM, each user still has to **allow the camera once** and **enroll**. Nobody else can enroll for them, and that's by design.

!!! info "Start at login is still a user action"
    The managed login item payload approves the agent and stops the user from disabling it in System Settings. It does **not** register it. Registration happens when the user turns on **Settings › Start at login** (ADR-0018). Having the app turn it on by itself on managed Macs would be a new decision (ADR) and isn't built.

## Permissions and payloads

| Permission | Asked when | Can MDM pre-grant it? |
|---|---|---|
| Camera | First launch | **No.** PPPC can only **deny** Camera. The user clicks Allow once. |
| Login item / background item | Start at login is turned on | **Yes**, with a managed login items payload. |
| Notifications | First launch | **Yes**, with a notification settings payload. |
| Location | Only if the user trusts a Wi-Fi network | No. |
| Local Network | Only for the trusted-Wi-Fi router check | No. |
| Keychain access | Reading the enrollment | Not a TCC permission. It goes away with a stable Team-ID signature (ND-050). |

### Managed login item (Service Management)

Payload type `com.apple.servicemanagement` (macOS 13+). It pre-approves the bundled agent, so users don't get the "Background Items Added" approval and can't switch it off in System Settings. They can still use the app's own Quit, which is confirmed and triggers the "was quit" reminder ([ADR-0018](adr/0018-bundled-keepalive-agent.md)).

Prefer the **Team ID + label** rule: it only matches code signed by your team. A bundle-id-only rule matches any binary that claims that id.

```xml
<!-- TEMPLATE: verify with IT. Needs the ND-050 Team ID. -->
<dict>
    <key>PayloadType</key>
    <string>com.apple.servicemanagement</string>
    <key>PayloadIdentifier</key>
    <string>com.nodonuts.app.managed-login-item</string>
    <key>PayloadUUID</key>
    <string>REPLACE-WITH-uuidgen</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>Rules</key>
    <array>
        <dict>
            <key>RuleType</key>
            <string>Label</string>
            <key>RuleValue</key>
            <string>com.nodonuts.app.agent</string>
            <key>TeamIdentifier</key>
            <string>TEAMID1234</string>
            <key>Comment</key>
            <string>No Donuts bundled KeepAlive agent (ADR-0018)</string>
        </dict>
    </array>
</dict>
```

Alternatives if your MDM prefers them: `RuleType` `TeamIdentifier` with `RuleValue` `TEAMID1234` (approves everything your team signs), or `BundleIdentifier` `com.nodonuts.app`.

### Camera: PPPC can't pre-grant it

The Privacy Preferences Policy Control payload (`com.apple.TCC.configuration-profile-policy`) can set Camera only to **Deny**. Apple doesn't let MDM grant the camera (or the microphone, or screen recording) without the user. So:

- **Don't** ship a Camera PPPC entry for No Donuts. The only possible value would block the app.
- Tell users to expect one "No Donuts would like to access the camera" prompt, and to click **Allow**.
- If a user clicked Don't Allow: System Settings › Privacy & Security › Camera › turn No Donuts on. The app shows an honest "not protecting" state until then (ND-086).
- The grant is tied to the code signature. Keep one Developer ID identity across releases, or users get asked again after every update ([ADR-0021](adr/0021-updates-no-in-app-updater.md)).

No Donuts doesn't need Accessibility, Screen Recording, Full Disk Access or Input Monitoring, so there's nothing else to put in a PPPC profile.

### Notifications

**Important.** The safety alarms are local notifications: "No Donuts isn't running" (the dead-man alert, ADR-0018), "Couldn't lock your Mac" (ND-054), "Not protecting" and "Identity off" (ND-073). If notifications are denied, none of them can fire, and after a kill nothing tells the user. The app shows a persistent menu warning in that case (ND-113), but pre-enabling notifications is the real fix.

Payload type `com.apple.notificationsettings`. `AlertType` `2` means persistent **Alerts** (they stay on screen until dismissed), which suits these warnings better than banners that disappear. Use `1` (banners) if your users object.

```xml
<!-- TEMPLATE: verify with IT. -->
<dict>
    <key>PayloadType</key>
    <string>com.apple.notificationsettings</string>
    <key>PayloadIdentifier</key>
    <string>com.nodonuts.app.notifications</string>
    <key>PayloadUUID</key>
    <string>REPLACE-WITH-uuidgen</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>NotificationSettings</key>
    <array>
        <dict>
            <key>BundleIdentifier</key>
            <string>com.nodonuts.app</string>
            <key>NotificationsEnabled</key>
            <true/>
            <key>AlertType</key>
            <integer>2</integer>
            <key>ShowInLockScreen</key>
            <true/>
            <key>ShowInNotificationCenter</key>
            <true/>
            <key>SoundsEnabled</key>
            <true/>
            <key>BadgesEnabled</key>
            <false/>
        </dict>
    </array>
</dict>
```

To check on a test Mac: the menu must **not** show "Notifications off", and **Copy diagnostics** should report notifications as authorized.

### Location and Local Network

Both are used only by **trusted Wi-Fi** (skip locking on a network the user marked as theirs). A user who never trusts a network never sees either prompt.

- **Location:** macOS only exposes the Wi-Fi name (SSID) to apps with Location permission. MDM can't grant per-app Location. Location Services must also be on system-wide, and some companies turn it off by policy. If so, trusted Wi-Fi can't work, and the rest of the app is unaffected.
- **Local Network:** used to read the router's hardware (MAC) address, so a look-alike hotspot with the same name isn't trusted. Nothing is sent. There's no MDM grant for it; the user allows it once.

Security note for IT: you may prefer to **disable trusted Wi-Fi** on company Macs, because "never lock on this network" is a policy choice. There's no managed setting for that yet. If you want one, file a backlog item.

### Keychain prompts

With today's dev signatures, macOS asks "NoDonuts wants to use your confidential information" after each rebuild. The login-keychain ACL falls back to the binary hash when there's no Team ID (ND-102). A **Developer ID signature with a Team ID** (ND-050) makes the ACL stable across updates, so users see it at most once (for example after a bundle-id change, ND-065).

## Updates

There's no in-app updater, and the app makes no internet connections ([ADR-0021](adr/0021-updates-no-in-app-updater.md)).

- **DMG:** the user quits No Donuts (confirm Quit), replaces `/Applications/NoDonuts.app` with the new version and opens it. Enrollment, settings and the camera grant carry over, as long as the bundle id and signing identity haven't changed.
- **MDM:** push the new `.pkg`. The KeepAlive agent relaunches the new binary. Prefer MDM for urgent security fixes.
- The version is shown in the menu, in Settings and in **Copy diagnostics**. Ask for it in every bug report.

## Uninstall

`scripts/uninstall.sh` is self-contained: IT can ship that one file or run it from an MDM script. Run it **as the logged-in user, never with sudo**, because everything it removes lives in the user's session. The script refuses to run as root.

```sh
scripts/uninstall.sh --dry-run          # show what it would do; changes nothing
scripts/uninstall.sh                    # stop, unregister start at login, remove the app; KEEP data
scripts/uninstall.sh --purge            # ...and delete ALL local data (asks you to type "yes")
scripts/uninstall.sh --purge --yes      # same, no prompt (scripted / MDM use)
scripts/uninstall.sh --keep-app         # just stop it and turn off start at login
```

Steps, in order:

1. Boot out the bundled agent (so launchd doesn't relaunch what it stops), then stop any running copy.
2. Run `NoDonuts --unregister`. This removes the start-at-login registration and clears pending notifications, so no "No Donuts isn't running" alert appears 10 minutes after uninstalling. It needs the app binary, which is why it runs before the app is deleted.
3. Remove the legacy `~/Library/LaunchAgents/com.nodonuts.agent.plist`, if present.
4. With `--purge`: delete the Keychain enrollment item, `defaults delete com.nodonuts.app`, `tccutil reset All com.nodonuts.app` (this bundle id only), and the fixed folders `~/Library/Application Support/NoDonuts`, `~/Library/Caches/com.nodonuts.app`, `~/Library/HTTPStorages/com.nodonuts.app`, and `~/Library/Saved Application State/com.nodonuts.app.savedState`.
5. Remove `/Applications/NoDonuts.app`, after checking its bundle id. A symlink or a different app at that path is refused.

The script finishes with a "What's left" line, and exits `1` if any step failed.

- **Installed by MDM as root:** removing `/Applications/NoDonuts.app` may need admin rights. The script says so, and IT can remove the app with the MDM. Run the per-user part (`uninstall.sh --purge --yes`) in each user's session **before** removing the app, because step 2 needs the binary.
- **Not removable by script** (no face data in any of them): the Location and Local Network decisions (macOS drops them once the app is gone), the entry in System Settings › Notifications, and crash reports in `~/Library/Logs/DiagnosticReports`.
- **Handing a Mac to someone else:** run `--purge` first. The enrollment lives in the legacy login keychain, which ignores `ThisDeviceOnly` and can be carried along by Migration Assistant or a backup restore ([SECURITY_PRIVACY](SECURITY_PRIVACY.md), threat model "Keychain at rest").
- An MDM **managed login item** profile stays in place until IT removes it. It only approves the agent and doesn't start anything once the app is gone.

`scripts/uninstall-launchagent.sh` is kept as an alias for `uninstall.sh --keep-app`.

## Privacy notes for colleagues and IT

What you can tell people, and check:

- **Everything is on-device.** Camera frames are analysed in memory and dropped right away. Nothing is recorded, saved or sent. The app makes no internet connections, has no telemetry and no updater ([ADR-0021](adr/0021-updates-no-in-app-updater.md)). IT can check this with a firewall or `nettop`.
- **What's stored:** one face **embedding** (numbers, not a photo) for the enrolled user, in their login Keychain, plus settings in `com.nodonuts.app`. Other people's faces seen by the camera are treated as "stranger" in memory and never stored.
- **How to delete it:** the menu's **Reset enrollment** (embedding only), or `scripts/uninstall.sh --purge` (everything).

!!! danger "Biometric data: sign-off needed before rollout (ND-111, deferred)"
    A face embedding is **biometric personal information**. Before deploying to colleagues:

    - Get sign-off from the company **privacy officer** and IT security. Also tell them the app locks the screen through a private API ([ADR-0010](adr/0010-screen-lock-no-accessibility.md)).
    - **Québec (Law 25):** using biometrics to verify identity needs the person's **express consent**. Creating a biometric identification system must be **declared to the Commission d'accès à l'information (CAI) in advance**, under the Act to establish a legal framework for information technology. The privacy officer should confirm the exact obligations and timelines.
    - The plain-language **privacy notice and consent screen** is built (ND-123, ADR-0024 (d)). Nobody can enroll without clicking **I agree** on the current notice; an enrollment that already exists without consent is asked about once per launch (agree, or decline and delete it). The answer is kept in the app's defaults (`defaults read com.nodonuts.app` → `privacyConsent.*`) and shown in **Copy diagnostics**. Users can re-read it or withdraw in Settings › About › **Privacy notice…**.
    - **Before rollout, fill in the contact:** the notice ends with "contact *your company's privacy officer or IT contact*", a placeholder. Replace the value of that key in `Resources/en.lproj/Localizable.strings` and `Resources/fr.lproj/Localizable.strings` with the real contact, then rebuild. A contact change doesn't need a notice-version bump; a change to what's stored or how does (`PrivacyConsentPolicy.currentNoticeVersion`).
    - The consent screen covers the app's side only. The privacy officer's check and the **CAI declaration** remain the company's to do.
    - Using it has to be voluntary, and a colleague who says no needs an alternative (for example the normal auto-lock).
    - Check that the face model's licence allows internal use at a for-profit company (ND-089).

## See also

- [ADR-0018: bundled KeepAlive agent](adr/0018-bundled-keepalive-agent.md) · [ADR-0021: updates](adr/0021-updates-no-in-app-updater.md) · [ADR-0015: built-in camera only](adr/0015-camera-trust-built-in-only.md) · [ADR-0008: app packaging](adr/0008-app-packaging.md)
- [Security & Privacy](SECURITY_PRIVACY.md) · [Edge cases](EDGE_CASES.md) · [Backlog](BACKLOG.md) (ND-050, ND-051, ND-052, ND-053, ND-111)
