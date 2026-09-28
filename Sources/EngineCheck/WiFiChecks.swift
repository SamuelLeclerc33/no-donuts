import Foundation
import CoreImage
import CoreVideo
import ImageIO
import IOKit.audio
import NoDonutsCore
// Owner: see CLAUDE.md module table. Split out of main.swift (ND-114) — pure move.

/// TrustedNetworksStore, RouterReadCache, gateway MAC parsing (ND-036, ND-081).
@MainActor
func runWiFiTrustChecks(_ c: Checks) async {
    // TrustedNetworksStore (ND-036 → ND-081): trust = SSID + default-gateway MAC.
    // Backed by throwaway UserDefaults suites (unique names) so nothing touches real
    // prefs. Fail-safe matrix: only SSID match + MAC match → trusted.
    do {
        func makeSuite() -> (UserDefaults, String)? {
            let name = "com.nodonuts.enginecheck.\(UUID().uuidString)"
            return UserDefaults(suiteName: name).map { ($0, name) }
        }
        let macA = "bc:df:58:e2:de:5f"
        let macB = "a4:2b:b0:01:02:03"
        if let (suite, name) = makeSuite() {
            let store = TrustedNetworksStore(defaults: suite)
            c.expect(!store.isTrusted(ssid: nil, gatewayMAC: nil)
                     && !store.isTrusted(ssid: "", gatewayMAC: macA)
                     && !store.isTrusted(ssid: "Home", gatewayMAC: macA),
                     "ND-081: empty store / nil or empty SSID → not trusted")
            c.expect(!store.trust(ssid: "Home", gatewayMAC: nil)
                     && !store.trust(ssid: "Home", gatewayMAC: "00:00:00:00:00:00")
                     && !store.trust(ssid: "Home", gatewayMAC: "not-a-mac")
                     && !store.trust(ssid: "", gatewayMAC: macA)
                     && store.count == 0,
                     "ND-081: trust() refuses without an SSID and a valid router MAC (nothing stored)")
            let added = store.trust(ssid: "Home", gatewayMAC: macA.uppercased())
            c.expect(added && store.isTrusted(ssid: "Home", gatewayMAC: macA)
                     && store.isTrusted(ssid: "Home", gatewayMAC: "BC-DF-58-E2-DE-5F"),
                     "ND-081: SSID match + MAC match → trusted (MAC case/separator normalized)")
            c.expect(!store.isTrusted(ssid: "Home", gatewayMAC: macB),
                     "ND-081: SSID match + MAC MISMATCH (hotspot copying the SSID) → NOT trusted")
            c.expect(!store.isTrusted(ssid: "Home", gatewayMAC: nil)
                     && !store.isTrusted(ssid: "Home", gatewayMAC: "garbage"),
                     "ND-081: SSID match + router MAC unreadable/invalid → NOT trusted (fail-safe)")
            c.expect(!store.isTrusted(ssid: "Other", gatewayMAC: macA) && !store.isTrusted(ssid: "home", gatewayMAC: macA),
                     "ND-081: router MAC match on a different SSID → NOT trusted")
            c.expect(store.status(ssid: "Home", gatewayMAC: macA) == .trusted
                     && store.status(ssid: "Home", gatewayMAC: macB) == .otherRouter
                     && store.status(ssid: "Home", gatewayMAC: nil) == .otherRouter
                     && store.status(ssid: "Other", gatewayMAC: macA) == .notTrusted
                     && store.status(ssid: nil, gatewayMAC: macA) == .notTrusted,
                     "ND-081: status(): trusted / otherRouter / notTrusted for the menu label")
            store.trust(ssid: "Home", gatewayMAC: macB)
            let bothRouters = store.isTrusted(ssid: "Home", gatewayMAC: macA)
                && store.isTrusted(ssid: "Home", gatewayMAC: macB) && store.count == 2
            store.untrust(ssid: "Home", gatewayMAC: macA)
            c.expect(bothRouters && !store.isTrusted(ssid: "Home", gatewayMAC: macA)
                     && store.isTrusted(ssid: "Home", gatewayMAC: macB) && store.count == 1,
                     "ND-081: one SSID can be trusted on several routers; untrust removes only this router")
            store.remove(TrustedNetwork(ssid: "Home", gatewayMAC: macB))
            c.expect(store.count == 0 && !store.isTrusted(ssid: "Home", gatewayMAC: macB),
                     "ND-081: remove(entry) (Settings) drops that SSID + router")
            // A hand-edited entry with an invalid MAC decodes as legacy → never trusted.
            suite.set([["ssid": "Edited", "gatewayMAC": "zz:zz"]], forKey: "trustedWiFiNetworks")
            c.expect(!store.isTrusted(ssid: "Edited", gatewayMAC: "zz:zz")
                     && store.status(ssid: "Edited", gatewayMAC: macA) == .needsReTrust,
                     "ND-081: stored entry with an invalid MAC → legacy (needs re-trust), not trusted")
            UserDefaults.standard.removePersistentDomain(forName: name)
        } else {
            c.expect(false, "ND-081: could not create a throwaway UserDefaults suite")
        }

        // Migration: the pre-ND-081 SSID-only list becomes legacy entries that need a
        // re-confirm. They are NOT auto-bound to the router present at upgrade time.
        if let (suite, name) = makeSuite() {
            suite.set(["Home", "Cafe", "Work", ""], forKey: "trustedWiFiSSIDs")
            suite.set([["ssid": "Work", "gatewayMAC": macB]], forKey: "trustedWiFiNetworks")
            let store = TrustedNetworksStore(defaults: suite)
            let entries = store.all()
            let legacySSIDs = entries.filter(\.needsReTrust).map(\.ssid)
            c.expect(legacySSIDs == ["Cafe", "Home"] && entries.count == 3
                     && suite.object(forKey: "trustedWiFiSSIDs") == nil,
                     "ND-081 migration: SSID-only entries → legacy (needs re-trust); old key removed; no dup for an already-bound SSID; empty dropped")
            c.expect(!store.isTrusted(ssid: "Home", gatewayMAC: macA)
                     && store.status(ssid: "Home", gatewayMAC: macA) == .needsReTrust
                     && store.needsReTrustCount == 2,
                     "ND-081 migration: a legacy entry is NOT trusted on any router (enforcement stays on)")
            c.expect(store.isTrusted(ssid: "Work", gatewayMAC: macB),
                     "ND-081 migration: an already-bound entry keeps working")
            store.trust(ssid: "Home", gatewayMAC: macA)
            c.expect(store.isTrusted(ssid: "Home", gatewayMAC: macA)
                     && store.status(ssid: "Home", gatewayMAC: macA) == .trusted
                     && store.needsReTrustCount == 1 && store.count == 3,
                     "ND-081 migration: re-confirming binds the legacy entry to this router (replaces it)")
            let again = TrustedNetworksStore(defaults: suite).all()
            c.expect(again == store.all(), "ND-081 migration: idempotent across store instances")
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
    }

    // RouterReadCache (ND-081 review): trust needs a FRESH read. A cached MAC for a
    // cloneable key must not survive an invalidation (poll / wake / Wi-Fi event).
    do {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let key = "en0|Home|aa:bb:cc:dd:ee:01"
        var cache = RouterReadCache(freshnessLimit: 25, negativeLifetime: 30)
        c.expect(cache.lookup(key: key, now: t0) == .none, "ND-081 cache: empty → none (read needed, not trusted)")
        let gen = cache.generation
        cache.record(key: key, generation: gen, mac: "bc:df:58:e2:de:5f", now: t0)
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(10)) == .fresh("bc:df:58:e2:de:5f"),
                 "ND-081 cache: read in the current generation → fresh")
        c.expect(cache.lookup(key: "en0|Other|x", now: t0) == .none,
                 "ND-081 cache: different key → none")
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(26)) == .none,
                 "ND-081 cache: older than the freshness limit → not fresh (backstop)")
        cache.invalidate(clearFailures: false)   // e.g. 15 s poll or wake
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(1)) == .none,
                 "ND-081 cache: SAME key after an invalidation → not fresh (evil twin can clone the key)")
        c.expect(!cache.record(key: key, generation: gen, mac: "bc:df:58:e2:de:5f", now: t0.addingTimeInterval(2))
                 && cache.lookup(key: key, now: t0.addingTimeInterval(2)) == .none,
                 "ND-081 cache: a read STARTED before the invalidation is discarded when it lands")
        cache.record(key: key, generation: cache.generation, mac: nil, now: t0.addingTimeInterval(3))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(20)) == .recentlyFailed
                 && cache.lookup(key: key, now: t0.addingTimeInterval(34)) == .none,
                 "ND-081 cache: failed read negative-cached for 30 s, then retried")
        cache.invalidate(clearFailures: false)
        let keptAcrossPoll = cache.lookup(key: key, now: t0.addingTimeInterval(5)) == .recentlyFailed
        cache.invalidate(clearFailures: true)    // Wi-Fi event / wake / Trust click
        c.expect(keptAcrossPoll && cache.lookup(key: key, now: t0.addingTimeInterval(5)) == .none,
                 "ND-081 cache: poll keeps the negative cache; events/wake clear it")
        cache.record(key: key, generation: cache.generation, mac: "bc:df:58:e2:de:5f", now: t0.addingTimeInterval(6))
        cache.record(key: key, generation: cache.generation, mac: nil, now: t0.addingTimeInterval(7))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(8)) == .recentlyFailed,
                 "ND-081 cache: a later failure for the key drops the verified MAC")
    }

    // Periodic re-verification hold (camera-every-15 s fix): the 15 s poll of an
    // unchanged key holds the previous verified answer for ≤ holdWindow while the
    // re-read is pending; nothing else ever holds.
    do {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let key = "en0|Home|aa:bb:cc:dd:ee:01"
        let mac = "bc:df:58:e2:de:5f"
        func verifiedCache(at t: Date) -> RouterReadCache {
            var cache = RouterReadCache(freshnessLimit: 25, negativeLifetime: 30, holdWindow: 5)
            cache.record(key: key, generation: cache.generation, mac: mac, now: t)
            return cache
        }

        var cache = verifiedCache(at: t0)
        cache.reverify(now: t0.addingTimeInterval(15))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(15)) == .held(mac)
                 && cache.lookup(key: key, now: t0.addingTimeInterval(19.9)) == .held(mac),
                 "hold: poll re-verify of an unchanged key holds the verified MAC while pending")
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(20)) == .none,
                 "hold: expires after holdWindow without a result → not trusted")
        c.expect(cache.lookup(key: "en0|Home|aa:bb:cc:dd:ee:99", now: t0.addingTimeInterval(16)) == .none,
                 "hold: a different key (BSSID change) never sees the held MAC")
        let gen = cache.generation
        cache.record(key: key, generation: gen, mac: mac, now: t0.addingTimeInterval(16))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(16)) == .fresh(mac),
                 "hold: matching re-read lands → fresh (trust continues without a flip)")

        cache = verifiedCache(at: t0)
        cache.reverify(now: t0.addingTimeInterval(15))
        cache.record(key: key, generation: cache.generation, mac: "de:ad:be:ef:00:01", now: t0.addingTimeInterval(16))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(16)) == .fresh("de:ad:be:ef:00:01"),
                 "hold: MISMATCHING re-read replaces the held MAC at once (store then refuses trust)")

        cache = verifiedCache(at: t0)
        cache.reverify(now: t0.addingTimeInterval(15))
        cache.record(key: key, generation: cache.generation, mac: nil, now: t0.addingTimeInterval(16))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(16)) == .recentlyFailed,
                 "hold: unreadable re-read drops trust at once")

        cache = verifiedCache(at: t0)
        cache.reverify(now: t0.addingTimeInterval(15))
        cache.invalidate(clearFailures: true)   // wake / Wi-Fi event / Trust click
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(15.5)) == .none,
                 "hold: a wake/Wi-Fi event during the hold cancels it (fail-safe)")

        cache = verifiedCache(at: t0)
        cache.invalidate(clearFailures: true)   // wake / Wi-Fi event: never holds
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(1)) == .none,
                 "hold: wake / Wi-Fi event / Trust click never hold")

        cache = verifiedCache(at: t0)
        cache.reverify(now: t0.addingTimeInterval(15))   // re-read never lands
        cache.reverify(now: t0.addingTimeInterval(30))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(30)) == .none,
                 "hold: never chained — a poll holds only from a read that landed")

        cache = verifiedCache(at: t0)
        cache.reverify(now: t0.addingTimeInterval(26))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(26)) == .none,
                 "hold: a verified read past the freshness limit is not held")

        cache = verifiedCache(at: t0)
        cache.reverify(now: t0.addingTimeInterval(15))
        cache.record(key: key, generation: cache.generation - 1, mac: mac, now: t0.addingTimeInterval(16))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(21)) == .none,
                 "hold: a stale (pre-poll) read landing does not extend the hold")
    }

    // Gateway MAC parsing (ND-081): MAC normalization, sysctl routing/ARP dumps built
    // from the real Darwin `rt_msghdr` layout, and the route(8)/arp(8) text fallbacks.
    do {
        c.expect(MACAddress.normalize("bc:df:58:e2:de:5f") == "bc:df:58:e2:de:5f"
                 && MACAddress.normalize("A4:2B:B0:1:2:3") == "a4:2b:b0:01:02:03"
                 && MACAddress.normalize(" a4-2b-b0-01-02-03\n") == "a4:2b:b0:01:02:03",
                 "ND-081: MAC normalize: case, 1-digit octets, '-' separators")
        c.expect(MACAddress.normalize("00:00:00:00:00:00") == nil
                 && MACAddress.normalize("ff:ff:ff:ff:ff:ff") == nil
                 && MACAddress.normalize("(incomplete)") == nil
                 && MACAddress.normalize("a4:2b:b0:01:02") == nil
                 && MACAddress.normalize("a4:2b:b0:01:02:0g") == nil
                 && MACAddress.normalize("a4:2b:b0:01:02:003") == nil
                 && MACAddress.normalize("") == nil,
                 "ND-081: MAC normalize rejects zero/broadcast/incomplete/short/non-hex")
        c.expect(MACAddress.format([0xbc, 0xdf, 0x58, 0xe2, 0xde, 0x5f]) == "bc:df:58:e2:de:5f"
                 && MACAddress.format([]) == nil && MACAddress.format([1, 2, 3]) == nil,
                 "ND-081: MAC format from bytes (6 bytes only)")

        func pad4(_ b: [UInt8]) -> [UInt8] {
            let n = b.isEmpty ? 4 : 1 + ((b.count - 1) | 3)
            return b + [UInt8](repeating: 0, count: n - b.count)
        }
        func sin(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
            [16, UInt8(AF_INET), 0, 0, a, b, c, d] + [UInt8](repeating: 0, count: 8)
        }
        /// Truncated netmask as the kernel writes it (sa_len covers the non-zero bytes).
        func mask(_ bytes: [UInt8]) -> [UInt8] {
            bytes.isEmpty ? [] : [UInt8(4 + bytes.count), 0xff, 0, 0] + bytes
        }
        func sdl(index: UInt16, name: String = "", mac: [UInt8]) -> [UInt8] {
            let n = Array(name.utf8)
            var b: [UInt8] = [0, UInt8(AF_LINK), UInt8(index & 0xff), UInt8(index >> 8),
                              6 /* IFT_ETHER */, UInt8(n.count), UInt8(mac.count), 0] + n + mac
            if b.count < 20 { b += [UInt8](repeating: 0, count: 20 - b.count) }
            b[0] = UInt8(b.count)
            return b
        }
        /// One routing message: real `rt_msghdr` bytes + sockaddrs in RTA bit order.
        func msg(flags: Int32, index: UInt16, dst: [UInt8]?, gw: [UInt8]?, netmask: [UInt8]?,
                 version: UInt8 = UInt8(RTM_VERSION)) -> [UInt8] {
            var addrs: Int32 = 0
            var body: [UInt8] = []
            if let dst { addrs |= RTA_DST; body += pad4(dst) }
            if let gw { addrs |= RTA_GATEWAY; body += pad4(gw) }
            if let netmask { addrs |= RTA_NETMASK; body += pad4(netmask) }
            var h = rt_msghdr()
            h.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
            h.rtm_version = version
            h.rtm_type = UInt8(RTM_GET)
            h.rtm_index = index
            h.rtm_flags = flags
            h.rtm_addrs = addrs
            return withUnsafeBytes(of: &h) { Array($0) } + body
        }
        let en0: UInt16 = 15, utun: UInt16 = 20
        let upGw = RTF_UP | RTF_GATEWAY
        let routes: [UInt8] =
            // 10.1.0.0/16 via 192.168.86.254 on en0: a gateway route, but not the default.
            msg(flags: upGw, index: en0, dst: sin(10, 1, 0, 0), gw: sin(192, 168, 86, 254), netmask: mask([255, 255]))
            // VPN full-tunnel default on utun: must NOT be taken for the Wi-Fi router.
            + msg(flags: upGw | RTF_STATIC, index: utun, dst: sin(0, 0, 0, 0), gw: sin(10, 0, 0, 1), netmask: mask([]))
            // Wrong rtm_version: skipped.
            + msg(flags: upGw, index: en0, dst: sin(0, 0, 0, 0), gw: sin(6, 6, 6, 6), netmask: mask([]), version: 99)
            // Scoped default on en0, then the unscoped one (preferred).
            + msg(flags: upGw | RTF_IFSCOPE, index: en0, dst: sin(0, 0, 0, 0), gw: sin(192, 168, 86, 2), netmask: mask([]))
            + msg(flags: upGw | RTF_STATIC, index: en0, dst: sin(0, 0, 0, 0), gw: sin(192, 168, 86, 1), netmask: mask([]))
        let parsed = GatewayRouteParser.parse(routes)
        c.expect(parsed.count == 4 && parsed.first?.netmask == .inet("255.255.0.0")
                 && parsed.first?.destination == .inet("10.1.0.0"),
                 "ND-081: route dump decodes rt_msghdr + padded sockaddrs (bad version skipped)")
        c.expect(GatewayRouteParser.defaultGateway(in: parsed, interfaceIndex: en0) == "192.168.86.1",
                 "ND-081: default gateway on the Wi-Fi interface (unscoped preferred; /16 route ignored)")
        c.expect(GatewayRouteParser.defaultGateway(in: parsed, interfaceIndex: utun) == "10.0.0.1"
                 && GatewayRouteParser.defaultGateway(in: parsed, interfaceIndex: 99) == nil,
                 "ND-081: default gateway is per-interface (a VPN's default isn't Wi-Fi's); none → nil")
        let scopedOnly = GatewayRouteParser.parse(
            msg(flags: upGw | RTF_IFSCOPE, index: en0, dst: sin(0, 0, 0, 0), gw: sin(192, 168, 86, 2), netmask: mask([])))
        let downRoute = GatewayRouteParser.parse(
            msg(flags: RTF_GATEWAY, index: en0, dst: sin(0, 0, 0, 0), gw: sin(192, 168, 86, 1), netmask: mask([])))
        c.expect(GatewayRouteParser.defaultGateway(in: scopedOnly, interfaceIndex: en0) == "192.168.86.2"
                 && GatewayRouteParser.defaultGateway(in: downRoute, interfaceIndex: en0) == nil,
                 "ND-081: scoped-only default is used; a route that isn't UP is not")
        let truncated = Array(routes.prefix(routes.count - 3))
        c.expect(GatewayRouteParser.parse([]).isEmpty && GatewayRouteParser.parse([1, 2, 3]).isEmpty
                 && GatewayRouteParser.parse(truncated).count == 3,
                 "ND-081: empty / short / truncated buffers parse safely (overrunning message dropped)")

        let router: [UInt8] = [0xbc, 0xdf, 0x58, 0xe2, 0xde, 0x5f]
        let arp: [UInt8] =
            // Same IP on another interface first (different MAC): must be skipped for en0.
            msg(flags: RTF_UP | RTF_LLINFO, index: utun, dst: sin(192, 168, 86, 1), gw: sdl(index: utun, mac: [2, 0, 0, 0, 0, 9]), netmask: nil)
            + msg(flags: RTF_UP | RTF_LLINFO, index: en0, dst: sin(192, 168, 86, 7), gw: sdl(index: en0, mac: []), netmask: nil)
            + msg(flags: RTF_UP | RTF_LLINFO, index: en0, dst: sin(192, 168, 86, 1), gw: sdl(index: en0, name: "en0", mac: router), netmask: nil)
        let arpParsed = GatewayRouteParser.parse(arp)
        c.expect(GatewayRouteParser.linkAddress(for: "192.168.86.1", in: arpParsed, interfaceIndex: en0) == "bc:df:58:e2:de:5f",
                 "ND-081: ARP dump → gateway MAC on the Wi-Fi interface (sockaddr_dl, name skipped)")
        c.expect(GatewayRouteParser.linkAddress(for: "192.168.86.7", in: arpParsed, interfaceIndex: en0) == nil
                 && GatewayRouteParser.linkAddress(for: "192.168.86.99", in: arpParsed, interfaceIndex: en0) == nil,
                 "ND-081: incomplete / missing ARP entry → nil (not trusted)")

        let routeGet = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.86.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        c.expect(GatewayRouteParser.parseRouteGetDefault(routeGet, interfaceName: "en0") == "192.168.86.1"
                 && GatewayRouteParser.parseRouteGetDefault(routeGet, interfaceName: "en1") == nil
                 && GatewayRouteParser.parseRouteGetDefault("route: writing to routing socket: not in table", interfaceName: "en0") == nil
                 && GatewayRouteParser.parseRouteGetDefault("gateway: fe80::1\ninterface: en0", interfaceName: "en0") == nil,
                 "ND-081: route(8) fallback: gateway only when the default is on the Wi-Fi interface")
        c.expect(GatewayRouteParser.parseArpOutput("? (192.168.86.1) at bc:df:58:e2:de:5f on en0 ifscope [ethernet]\n",
                                                   ip: "192.168.86.1", interfaceName: "en0") == "bc:df:58:e2:de:5f"
                 && GatewayRouteParser.parseArpOutput("? (10.0.0.1) at a4:2b:b0:1:2:3 on en0 [ethernet]",
                                                      ip: "10.0.0.1", interfaceName: "en0") == "a4:2b:b0:01:02:03",
                 "ND-081: arp(8) fallback: MAC parsed and normalized")
        c.expect(GatewayRouteParser.parseArpOutput("? (192.168.86.1) at (incomplete) on en0 ifscope [ethernet]",
                                                   ip: "192.168.86.1", interfaceName: "en0") == nil
                 && GatewayRouteParser.parseArpOutput("192.168.86.1 (192.168.86.1) -- no entry",
                                                      ip: "192.168.86.1", interfaceName: "en0") == nil
                 && GatewayRouteParser.parseArpOutput("? (192.168.86.1) at bc:df:58:e2:de:5f on en7 [ethernet]",
                                                      ip: "192.168.86.1", interfaceName: "en0") == nil
                 && GatewayRouteParser.parseArpOutput("? (192.168.86.10) at bc:df:58:e2:de:5f on en0 [ethernet]",
                                                      ip: "192.168.86.1", interfaceName: "en0") == nil,
                 "ND-081: arp(8) fallback: incomplete / no entry / other interface / other IP → nil")
    }
}
