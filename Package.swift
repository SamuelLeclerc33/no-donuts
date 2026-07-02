// swift-tools-version:6.0
import PackageDescription

// No Donuts — macOS menu-bar presence guard.
// NOTE: SPM is used for fast iteration on logic. The shippable, signed menu-bar
// .app bundle (Info.plist + camera entitlement + LSUIElement) requires full Xcode.
// See .claude/skills/build-run/SKILL.md and ADR-0001.
let package = Package(
    name: "NoDonuts",
    platforms: [.macOS(.v15)],
    targets: [
        // Foundation-only ObjC shim so Swift can survive AVFoundation setters
        // that throw NSException (e.g. AVCaptureDALDevice frame-duration). Must
        // stay CLT-buildable: no AVFoundation/AppKit imports here.
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher"
        ),
        // Testable, AppKit-free core: presence engine, camera/recognition/lock
        // protocols + stubs, shared types. Imported by the app and the checks.
        .target(
            name: "NoDonutsCore",
            dependencies: ["ObjCExceptionCatcher"],
            path: "Sources/NoDonutsCore"
        ),
        // The menu-bar app shell (AppKit). Owns main.swift + App/.
        .executableTarget(
            name: "NoDonuts",
            dependencies: ["NoDonutsCore"],
            path: "Sources/NoDonuts"
        ),
        // Framework-free engine checks. Runs in ANY toolchain (incl. Command
        // Line Tools, where XCTest/Swift-Testing are unavailable): `swift run EngineCheck`.
        .executableTarget(
            name: "EngineCheck",
            dependencies: ["NoDonutsCore"],
            path: "Sources/EngineCheck"
        )
    ]
)
