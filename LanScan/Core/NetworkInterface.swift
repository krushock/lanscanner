import Darwin
import SystemConfiguration

struct NetworkInterface: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case wifi, ethernet, other }

    /// One entry per IPv4 address, so an interface carrying several networks offers each of them.
    var id: String { "\(bsdName)/\(address)" }
    let bsdName: String
    let displayName: String
    let kind: Kind
    let address: IPv4
    let netmask: IPv4
    let macAddress: MACAddress?
    let router: IPv4?
    let isPrimary: Bool
    let ipv6Addresses: [IPv6]

    var prefixLength: Int { netmask.raw.nonzeroBitCount }
    var network: IPv4 { IPv4(raw: address.raw & netmask.raw) }
    var broadcast: IPv4 { IPv4(raw: address.raw | ~netmask.raw) }
    var cidr: String { "\(network)/\(prefixLength)" }
    var index: UInt32 { if_nametoindex(bsdName) }

    var symbol: String {
        switch kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .other: "network"
        }
    }

    /// The usable host range of the subnet, clamped to the /20 around our own address when larger.
    var hostRange: ClosedRange<IPv4>? {
        let prefix = max(prefixLength, 20)
        guard prefix < 31 else { return nil }
        let mask: UInt32 = ~UInt32(0) << (32 - prefix)
        let first = (address.raw & mask) + 1
        let last = (address.raw | ~mask) - 1
        guard first <= last else { return nil }
        return IPv4(raw: first)...IPv4(raw: last)
    }

    var label: String { "\(displayName) (\(bsdName)) · \(cidr)" }

    func contains(_ ip: IPv4) -> Bool { ip.raw & netmask.raw == network.raw }

    /// Active IPv4 interfaces, with the system's primary interface first.
    static func current() -> [NetworkInterface] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        var macs: [String: MACAddress] = [:]
        var candidates: [(name: String, address: IPv4, netmask: IPv4)] = []
        var ipv6: [String: [IPv6]] = [:]

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let addr = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)

            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                if let mac = MACAddress(sockaddrDL: UnsafeRawPointer(addr)), !mac.isZero { macs[name] = mac }
            case AF_INET:
                let required = IFF_UP | IFF_RUNNING | IFF_BROADCAST
                guard flags & required == required, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                      let mask = ifa.ifa_netmask else { continue }
                let ip = UnsafeRawPointer(addr).loadUnaligned(as: sockaddr_in.self).sin_addr
                let netmask = UnsafeRawPointer(mask).loadUnaligned(as: sockaddr_in.self).sin_addr
                let address = IPv4(ip)
                // Skip link-local (169.254/16) self-assigned addresses.
                guard address.raw >> 16 != 0xA9FE else { continue }
                candidates.append((name, address, IPv4(netmask)))
            case AF_INET6:
                let address = IPv6(UnsafeRawPointer(addr).loadUnaligned(as: sockaddr_in6.self).sin6_addr)
                ipv6[name, default: []].append(address)
            default:
                break
            }
        }

        let info = SystemNetworkInfo.load()
        return candidates.map { candidate in
            let sc = info.interfaces[candidate.name]
            return NetworkInterface(
                bsdName: candidate.name,
                displayName: sc?.displayName ?? candidate.name,
                kind: sc?.kind ?? .other,
                address: candidate.address,
                netmask: candidate.netmask,
                macAddress: macs[candidate.name],
                router: info.routers[candidate.name],
                isPrimary: info.primaryInterface == candidate.name,
                ipv6Addresses: (ipv6[candidate.name] ?? []).sorted()
            )
        }
        .sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            if lhs.bsdName != rhs.bsdName { return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending }
            return lhs.address < rhs.address
        }
    }
}

/// Details read from SystemConfiguration: friendly names, routers and DNS servers.
struct SystemNetworkInfo: Sendable {
    var interfaces: [String: (displayName: String, kind: NetworkInterface.Kind)] = [:]
    var routers: [String: IPv4] = [:]
    var primaryInterface: String?
    var dnsServers: [IPv4] = []

    static func load() -> SystemNetworkInfo {
        var info = SystemNetworkInfo()

        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
                let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsd
                let type = SCNetworkInterfaceGetInterfaceType(interface)
                let kind: NetworkInterface.Kind =
                    type == kSCNetworkInterfaceTypeIEEE80211 ? .wifi :
                    type == kSCNetworkInterfaceTypeEthernet ? .ethernet : .other
                info.interfaces[bsd] = (name, kind)
            }
        }

        guard let store = SCDynamicStoreCreate(nil, "LanScan" as CFString, nil, nil) else { return info }

        if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            info.primaryInterface = global["PrimaryInterface"] as? String
            if let primary = info.primaryInterface, let router = (global["Router"] as? String).flatMap(IPv4.init) {
                info.routers[primary] = router
            }
        }

        let pattern = "State:/Network/Service/.*/IPv4" as CFString
        if let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] {
            for key in keys {
                guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      let name = value["InterfaceName"] as? String,
                      let router = (value["Router"] as? String).flatMap(IPv4.init) else { continue }
                info.routers[name] = info.routers[name] ?? router
            }
        }

        if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
            info.dnsServers = (dns["ServerAddresses"] as? [String] ?? []).compactMap(IPv4.init)
        }
        return info
    }

    static var computerName: String? { SCDynamicStoreCopyComputerName(nil, nil) as String? }
    static var localHostName: String? { (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } }
}
