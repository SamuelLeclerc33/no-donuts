import Foundation
import Darwin
import NoDonutsCore
import os.log

// Owner: krusty — reads the Wi-Fi interface's default-gateway MAC (ND-081, EC-20).
//
// How (all read-only and local: no packets sent, nothing leaves the Mac):
//   1. Gateway IP: sysctl {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY}
//      → IPv4 default route on the Wi-Fi interface. No subprocess. Fallback to
//      `/sbin/route -n get default` only if the sysctl call itself fails.
//   2. Gateway MAC: sysctl {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO}
//      → ARP entry for that IP. Observed 2026-09-28 on macOS (Darwin 27): the kernel
//      returns an EMPTY ARP dump to non-platform binaries (our app), even though
//      `/usr/sbin/arp` issues the same MIB and gets entries. So when sysctl yields no
//      entry we fall back to `/usr/sbin/arp -n <ip>` (fixed path, no shell, 2 s cap).
//      WiFiMonitor caches results (and failures, for 30 s) and only reads for SSIDs
//      that have a trusted entry, so arp(8) doesn't run on every menu open.
// Decoding lives in NoDonutsCore (`GatewayRouteParser`, EngineCheck-covered).
//
// Runs OFF the main actor (WiFiMonitor calls it from a detached task), so neither
// the fallbacks nor their 2 s timeout can stall the menu or the enforcement gate.
//
// FAIL-SAFE: any unknown → nil → the network is NOT trusted → enforcement stays ON.
/// Outcome of one gateway read. Sendable so it can cross from the background read
/// to the main actor. `failure` / `method` are fixed labels for logging (never the
/// SSID, IP or MAC).
struct GatewayReadResult: Sendable, Equatable {
    /// Canonical MAC, or nil when the read failed.
    let mac: String?
    /// How the MAC was obtained ("sysctl" / "arp"), when it was.
    let method: String?
    /// Why it failed, e.g. "no-interface", "no-default-route",
    /// "route-sysctl-failed+route-tool-failed", "arp-sysctl-empty+arp-no-entry",
    /// "arp-sysctl-empty+arp-timeout". nil on success.
    let failure: String?
}

// Nonisolated and blocking: call it OFF the main actor (WiFiMonitor runs it in a
// detached task). The arp(8)/route(8) fallback can take up to its 2 s timeout.
enum GatewayResolver {
    private static let log = OSLog(subsystem: "com.nodonuts.app", category: "wifi")
    private static let toolTimeout: TimeInterval = 2

    /// Read the default gateway's MAC on `interfaceName` (e.g. "en0"). Logs a notice
    /// on failure with the step that failed (labels only, no values).
    static func resolve(interfaceName: String) -> GatewayReadResult {
        let result = resolveUnlogged(interfaceName: interfaceName)
        if let failure = result.failure {
            os_log("gateway read failed: %{public}@", log: log, type: .default, failure)
        } else {
            os_log("gateway read ok via %{public}@", log: log, type: .debug, result.method ?? "?")
        }
        return result
    }

    private static func resolveUnlogged(interfaceName: String) -> GatewayReadResult {
        let index = if_nametoindex(interfaceName)
        guard index != 0, index <= UInt32(UInt16.max) else {
            return GatewayReadResult(mac: nil, method: nil, failure: "no-interface")
        }
        let ifIndex = UInt16(index)

        // 1. Gateway IP.
        let gatewayIP: String?
        if let dump = routeDump(flags: RTF_GATEWAY) {
            gatewayIP = GatewayRouteParser.defaultGateway(in: GatewayRouteParser.parse(dump),
                                                          interfaceIndex: ifIndex)
            if gatewayIP == nil {
                return GatewayReadResult(mac: nil, method: nil, failure: "no-default-route")
            }
        } else {
            switch run("/sbin/route", ["-n", "get", "default"]) {
            case .output(let text):
                gatewayIP = GatewayRouteParser.parseRouteGetDefault(text, interfaceName: interfaceName)
                if gatewayIP == nil {
                    return GatewayReadResult(mac: nil, method: nil,
                                             failure: "route-sysctl-failed+no-default-route")
                }
            case .failed(let why):
                return GatewayReadResult(mac: nil, method: nil, failure: "route-sysctl-failed+route-\(why)")
            }
        }
        guard let gatewayIP else {
            return GatewayReadResult(mac: nil, method: nil, failure: "no-default-route")
        }

        // 2. MAC: ARP sysctl, then arp(8).
        let sysctlLabel: String
        if let dump = routeDump(flags: RTF_LLINFO) {
            if let mac = GatewayRouteParser.linkAddress(for: gatewayIP,
                                                        in: GatewayRouteParser.parse(dump),
                                                        interfaceIndex: ifIndex) {
                return GatewayReadResult(mac: mac, method: "sysctl", failure: nil)
            }
            sysctlLabel = dump.isEmpty ? "arp-sysctl-empty" : "arp-sysctl-no-entry"
        } else {
            sysctlLabel = "arp-sysctl-failed"
        }
        switch run("/usr/sbin/arp", ["-n", gatewayIP]) {
        case .output(let text):
            if let mac = GatewayRouteParser.parseArpOutput(text, ip: gatewayIP, interfaceName: interfaceName) {
                return GatewayReadResult(mac: mac, method: "arp", failure: nil)
            }
            return GatewayReadResult(mac: nil, method: nil, failure: "\(sysctlLabel)+arp-no-entry")
        case .failed(let why):
            // arp(8) exits 1 for "no entry"; that lands here as "exit-1".
            let label = why == "exit-1" ? "arp-no-entry" : "arp-\(why)"
            return GatewayReadResult(mac: nil, method: nil, failure: "\(sysctlLabel)+\(label)")
        }
    }

    /// Raw NET_RT_FLAGS dump for AF_INET routes carrying `flags`, or nil if sysctl
    /// fails. The table can grow between the size probe and the read (ENOMEM), so
    /// retry a few times with headroom.
    private static func routeDump(flags: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, flags]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            if size == 0 { return [] }
            size += size / 2 + 512
            var buffer = [UInt8](repeating: 0, count: size)
            let rc = buffer.withUnsafeMutableBytes {
                sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
            }
            if rc == 0 { return Array(buffer.prefix(size)) }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    private enum ToolResult {
        case output(String)
        /// "launch-failed" / "timeout" / "exit-<code>".
        case failed(String)
    }

    /// Run a system tool with a fixed path and args (no shell). Blocks the calling
    /// (background) thread until exit or the 2 s timeout, whichever comes first.
    private static func run(_ path: String, _ args: [String]) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failed("launch-failed") }
        guard exited.wait(timeout: .now() + toolTimeout) == .success else {
            process.terminate()
            return .failed("timeout")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return .failed("exit-\(process.terminationStatus)") }
        return String(data: data, encoding: .utf8).map(ToolResult.output) ?? .failed("bad-output")
    }
}
