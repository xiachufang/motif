import Foundation
@preconcurrency import TailscaleKit

// Tailnet host resolution + peer discovery.
extension TailscaleManager {
    /// Resolve a tailnet hostname (MagicDNS short name or full FQDN) to a
    /// concrete tailnet IP by walking the IPN peer list. iOS's stub
    /// resolver doesn't know `*.ts.net`, and URLSession's SOCKS5 path
    /// resolves hostnames locally before tunnelling — so dialling
    /// `ws://something.ts.net:port` blows up with NSURLErrorNetworkConnectionLost
    /// (-1005) the moment the SOCKS handshake tries to forward the
    /// resolved-but-bogus IP. Pre-resolving here keeps the WS open.
    ///
    /// Inputs that already look like an IP (digits + dots, or a colon)
    /// are returned unchanged. If no peer matches, returns nil — caller
    /// should fall back to the original string.
    func resolveTailnetHost(_ host: String) async -> String? {
        if Self.looksLikeIP(host) { return host }
        let peers = await discoverPeers()
        let normalized = host.lowercased()
        for peer in peers {
            let dns = peer.dnsName.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let shortName = peer.hostname.lowercased()
            if dns == normalized || dns.hasPrefix("\(normalized).") || shortName == normalized {
                if let ip = peer.primaryIP { return ip }
            }
        }
        return nil
    }

    private static func looksLikeIP(_ s: String) -> Bool {
        if s.contains(":") { return true } // very rough IPv6 sniff
        let parts = s.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return false
    }

    // MARK: - Discovery

    /// A tailnet peer that looks like a candidate motifd target. Hostnames
    /// matching `motifd*` (motif-server's default) bubble to the top, but
    /// we still surface every online peer so the user can pick a non-default
    /// host they renamed.
    struct DiscoveredPeer: Identifiable, Hashable, Sendable {
        var id: String { dnsName.isEmpty ? hostname : dnsName }
        var hostname: String
        var dnsName: String
        var primaryIP: String?
        var isLikelyMotifd: Bool
        var isOnline: Bool

        /// Best string to put in MotifServer.host: prefer the short MagicDNS
        /// name (without trailing dot), fall back to the v4 IP.
        var preferredAddress: String {
            if !dnsName.isEmpty {
                let trimmed = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
                return trimmed
            }
            return primaryIP ?? hostname
        }
    }

    /// Pull the current tailnet peer list from the local API. Empty when
    /// not connected. Online peers come first, motifd-named hosts come
    /// before anything else within each group.
    func discoverPeers() async -> [DiscoveredPeer] {
        guard let api = apiClient else { return [] }
        let status: IpnState.Status
        do {
            status = try await api.backendStatus()
        } catch {
            log.error("backendStatus: \(String(describing: error), privacy: .public)")
            return []
        }

        var peers: [DiscoveredPeer] = []
        if let me = status.SelfStatus {
            peers.append(Self.toDiscovered(me))
        }
        if let table = status.Peer {
            peers.append(contentsOf: table.values.map(Self.toDiscovered))
        }
        // Sort: online motifd-* > other online > offline. Stable name-sort
        // within each bucket.
        return peers.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
            if a.isLikelyMotifd != b.isLikelyMotifd { return a.isLikelyMotifd && !b.isLikelyMotifd }
            return a.hostname.localizedCaseInsensitiveCompare(b.hostname) == .orderedAscending
        }
    }

    private static func toDiscovered(_ p: IpnState.PeerStatus) -> DiscoveredPeer {
        let ipv4 = p.TailscaleIPs?.first(where: { $0.contains(".") })
        // motif-server names itself `motifd-<sanitized hostname>` (or just
        // `motifd`) by default — see default_ts_hostname() in
        // crates/motif-server/src/main.rs. Anything else (including this
        // iOS app's own `motif-ios` hostname) shouldn't surface as a
        // motifd target.
        let lower = p.HostName.lowercased()
        return DiscoveredPeer(
            hostname: p.HostName,
            dnsName: p.DNSName,
            primaryIP: ipv4,
            isLikelyMotifd: lower == "motifd" || lower.hasPrefix("motifd-"),
            isOnline: p.Online
        )
    }
}
