// swift-tools-version:6.0
import PackageDescription

// No Donuts — macOS menu-bar presence guard.
// NOTE: SPM is used for fast iteration on logic. The shippable, signed menu-bar
// .app bundle (Info.plist + camera entitlement + LSUIElement) requires full Xcode.
// See .claude/skills/build-run/SKILL.md and ADR-0001.
let package = Package(
    name: "NoDonuts",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NoDonuts",
            path: "Sources/NoDonuts"
        )
    ]
)
