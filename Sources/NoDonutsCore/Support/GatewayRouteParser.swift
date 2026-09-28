import Foundation
import Darwin

// Owner: krusty (+ wiggum review) — pure parsing for the trusted-Wi-Fi router check
// (ND-081, EC-20). A trusted network is SSID + the default gateway's MAC address, so
// a hotspot that merely broadcasts the trusted SSID is not trusted.
//
// Everything here is PURE: it takes bytes / text and returns values. The App layer
// (`GatewayResolver`) does the actual `sysctl` reads and hands the buffers in, so the
// byte-level decoding is checkable in EngineCheck with synthetic buffers built from
// the real Darwin struct layouts.
//
// Two sources, both read-only and local (no packets are sent, nothing leaves the Mac):
//   1. Routing table: sysctl {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY}
//      → the IPv4 default route (dst 0.0.0.0/0) on the Wi-Fi interface → gateway IP.
//   2. ARP table:     sysctl {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO}
//      → the entry for that IP → its link-layer (MAC) address.
// Text fallbacks (`route -n get default`, `arp -n <ip>`) parse the same answer when
// the sysctl read itself fails.
//
// FAIL-SAFE: every "can't tell" path returns nil, and nil is never trusted.

/// A MAC address in canonical form: six lowercase, zero-padded hex octets joined by
/// ":" (e.g. "bc:df:58:02:de:5f"). All-zero and broadcast addresses are rejected.
public enum MACAddress {
    /// Canonical string from raw bytes. nil unless exactly 6 bytes and not
    /// all-zero / all-0xff (an incomplete or bogus ARP entry).
    public static func format(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 6,
              !bytes.allSatisfy({ $0 == 0 }),
              !bytes.allSatisfy({ $0 == 0xff }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Canonical string from text. Accepts ":" or "-" separators and 1-2 hex digits
    /// per octet (`arp` prints "a4:2b:b0:1:2:3"). nil for anything else.
    public static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: trimmed.contains("-") ? "-" : ":",
                                  omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...2).contains(part.count),
                  part.allSatisfy(\.isHexDigit),
                  let b = UInt8(part, radix: 16) else { return nil }
            bytes.append(b)
        }
        return format(bytes)
    }
}

/// One decoded socket address from a routing message.
public enum RouteSockaddr: Equatable, Sendable {
    /// AF_INET address (dotted quad). Netmasks, which the kernel truncates, are
    /// decoded zero-padded.
    case inet(String)
    /// AF_LINK address: interface index + link-layer address bytes (MAC for Wi-Fi /
    /// Ethernet; empty for an incomplete ARP entry).
    case link(interfaceIndex: UInt16, address: [UInt8])
    /// A zero-length sockaddr (the kernel's encoding of a 0.0.0.0 netmask).
    case empty
    /// Any other family (ignored by the lookups).
    case other(family: UInt8)
}

/// One decoded `rt_msghdr` + its address slots (only the three we use).
public struct RouteMessage: Equatable, Sendable {
    public var flags: Int32
    public var interfaceIndex: UInt16
    public var destination: RouteSockaddr?
    public var gateway: RouteSockaddr?
    public var netmask: RouteSockaddr?

    public init(flags: Int32, interfaceIndex: UInt16,
                destination: RouteSockaddr?, gateway: RouteSockaddr?, netmask: RouteSockaddr?) {
        self.flags = flags
        self.interfaceIndex = interfaceIndex
        self.destination = destination
        self.gateway = gateway
        self.netmask = netmask
    }
}

public enum GatewayRouteParser {

    // MARK: - sysctl buffer decoding

    /// Darwin pads each sockaddr in a routing message to a 4-byte boundary
    /// (`ROUNDUP` with `sizeof(uint32_t)` in route.c); a zero length still takes 4.
    static func roundUp(_ length: Int) -> Int {
        length > 0 ? 1 + ((length - 1) | (MemoryLayout<UInt32>.size - 1)) : MemoryLayout<UInt32>.size
    }

    /// Decode a NET_RT_DUMP / NET_RT_FLAGS sysctl buffer into messages. Stops at the
    /// first malformed header (short length, overrun) rather than guessing; messages
    /// with a different `rtm_version` are skipped.
    public static func parse(_ buffer: [UInt8]) -> [RouteMessage] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        guard let lenOff = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_msglen),
              let verOff = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_version),
              let idxOff = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_index),
              let flagsOff = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_flags),
              let addrsOff = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_addrs)
        else { return [] }

        var messages: [RouteMessage] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + headerSize <= raw.count {
                let msgLen = Int(raw.loadUnaligned(fromByteOffset: offset + lenOff, as: UInt16.self))
                guard msgLen >= headerSize, offset + msgLen <= raw.count else { break }
                defer { offset += msgLen }
                let version = raw.loadUnaligned(fromByteOffset: offset + verOff, as: UInt8.self)
                guard Int32(version) == RTM_VERSION else { continue }
                let index = raw.loadUnaligned(fromByteOffset: offset + idxOff, as: UInt16.self)
                let flags = raw.loadUnaligned(fromByteOffset: offset + flagsOff, as: Int32.self)
                let addrs = raw.loadUnaligned(fromByteOffset: offset + addrsOff, as: Int32.self)

                var msg = RouteMessage(flags: flags, interfaceIndex: index,
                                       destination: nil, gateway: nil, netmask: nil)
                var cursor = offset + headerSize
                let end = offset + msgLen
                for bit in 0..<Int(RTAX_MAX) where addrs & (Int32(1) << Int32(bit)) != 0 {
                    guard cursor < end else { break }
                    let saLen = Int(raw[cursor])
                    guard cursor + max(saLen, 1) <= end else { break }
                    let bytes = Array(raw[cursor..<(cursor + saLen)])
                    let isNetmask = bit == Int(RTAX_NETMASK)
                    let decoded = decodeSockaddr(bytes, asNetmask: isNetmask)
                    switch bit {
                    case Int(RTAX_DST): msg.destination = decoded
                    case Int(RTAX_GATEWAY): msg.gateway = decoded
                    case Int(RTAX_NETMASK): msg.netmask = decoded
                    default: break
                    }
                    cursor += roundUp(saLen)
                }
                messages.append(msg)
            }
        }
        return messages
    }

    /// Decode one sockaddr (bytes include sa_len/sa_family). Netmasks are decoded as
    /// IPv4 regardless of family byte because the kernel truncates them.
    static func decodeSockaddr(_ bytes: [UInt8], asNetmask: Bool) -> RouteSockaddr {
        guard bytes.count >= 2 else { return .empty }
        let family = bytes[1]
        if asNetmask || Int32(family) == AF_INET {
            // sockaddr_in: len, family, port(2), addr(4) → address at bytes 4..<8.
            var quad = [UInt8](repeating: 0, count: 4)
            for i in 0..<4 where 4 + i < bytes.count { quad[i] = bytes[4 + i] }
            return .inet(quad.map(String.init).joined(separator: "."))
        }
        if Int32(family) == AF_LINK {
            // sockaddr_dl: len, family, index(2), type, nlen, alen, slen, data[…]
            guard bytes.count >= 8 else { return .other(family: family) }
            let index = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
            let nlen = Int(bytes[5])
            let alen = Int(bytes[6])
            let start = 8 + nlen
            guard start + alen <= bytes.count else {
                return .link(interfaceIndex: index, address: [])
            }
            return .link(interfaceIndex: index, address: Array(bytes[start..<(start + alen)]))
        }
        return .other(family: family)
    }

    // MARK: - Lookups

    private static func isAllZero(_ sa: RouteSockaddr?) -> Bool {
        switch sa {
        case nil, .empty?: return true
        case .inet(let s)?: return s == "0.0.0.0"
        default: return false
        }
    }

    /// The IPv4 default gateway on `interfaceIndex` (the Wi-Fi interface), from an
    /// RTF_GATEWAY dump. A default route = UP + GATEWAY, dst 0.0.0.0, mask 0.
    /// Restricting to the Wi-Fi interface keeps a VPN's default route (utun) from
    /// being taken for the router. Prefers the unscoped route when both exist.
    /// nil when there is none (fail-safe: not trusted).
    public static func defaultGateway(in messages: [RouteMessage], interfaceIndex: UInt16) -> String? {
        let candidates = messages.filter { m in
            m.flags & RTF_UP != 0 && m.flags & RTF_GATEWAY != 0
                && m.interfaceIndex == interfaceIndex
                && m.destination == .inet("0.0.0.0")
                && isAllZero(m.netmask)
        }
        let ordered = candidates.filter { $0.flags & RTF_IFSCOPE == 0 }
            + candidates.filter { $0.flags & RTF_IFSCOPE != 0 }
        for m in ordered {
            if case .inet(let ip)? = m.gateway, ip != "0.0.0.0" { return ip }
        }
        return nil
    }

    /// The MAC for `ip` from an RTF_LLINFO (ARP) dump, on `interfaceIndex`. nil for a
    /// missing or incomplete entry (fail-safe: not trusted).
    public static func linkAddress(for ip: String, in messages: [RouteMessage],
                                   interfaceIndex: UInt16) -> String? {
        for m in messages where m.destination == .inet(ip) {
            guard case let .link(sdlIndex, address)? = m.gateway else { continue }
            guard m.interfaceIndex == interfaceIndex || sdlIndex == interfaceIndex else { continue }
            if let mac = MACAddress.format(address) { return mac }
        }
        return nil
    }

    // MARK: - Text fallbacks

    /// Gateway IP from `route -n get default` output, only when its `interface:` is
    /// `interfaceName` (nil interface line → nil, fail-safe).
    public static func parseRouteGetDefault(_ output: String, interfaceName: String) -> String? {
        var gateway: String?
        var interface: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            if parts[0] == "gateway" { gateway = parts[1] }
            if parts[0] == "interface" { interface = parts[1] }
        }
        guard let gateway, interface == interfaceName, isDottedQuad(gateway),
              gateway != "0.0.0.0" else { return nil }
        return gateway
    }

    /// MAC for `ip` from `arp -n <ip>` output, e.g.
    /// "? (192.168.1.1) at bc:df:58:e2:de:5f on en0 ifscope [ethernet]".
    /// "(incomplete)" / "no entry" / another interface → nil.
    public static func parseArpOutput(_ output: String, ip: String, interfaceName: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let tokens = line.split(separator: " ").map(String.init)
            guard let paren = tokens.firstIndex(of: "(\(ip))"),
                  paren + 2 < tokens.count, tokens[paren + 1] == "at" else { continue }
            if let on = tokens.firstIndex(of: "on"), on + 1 < tokens.count,
               tokens[on + 1] != interfaceName { continue }
            if let mac = MACAddress.normalize(tokens[paren + 2]) { return mac }
        }
        return nil
    }

    static func isDottedQuad(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && (Int(p) ?? 256) <= 255
        }
    }
}
