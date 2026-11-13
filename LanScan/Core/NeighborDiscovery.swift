import Darwin

/// IPv6 discovery: ping the all-nodes group (ff02::1) from each of our IPv6 source addresses so that
/// every host answers from its matching address, then read the kernel's neighbor (NDP) cache,
/// which maps those addresses to MAC addresses.
enum NeighborDiscovery {
    static func discover(on interface: NetworkInterface, cancel: CancelToken) -> [MACAddress: [IPv6]] {
        let index = interface.index
        // Our link-local address plus one global address per /64 prefix is enough to reach everyone.
        var sources: [IPv6] = []
        for address in interface.ipv6Addresses where !sources.contains(where: { $0.prefix64 == address.prefix64 }) {
            sources.append(address)
        }

        for source in sources where !cancel.isCancelled {
            pingAllNodes(from: source, index: index, cancel: cancel)
        }
        guard !cancel.isCancelled else { return [:] }

        var neighbors: [MACAddress: [IPv6]] = [:]
        for entry in read() where entry.interfaceIndex == index && !entry.ip.isMulticast {
            neighbors[entry.mac, default: []].append(entry.ip)
        }
        return neighbors.mapValues { Array(Set($0)).sorted() }
    }

    private static func pingAllNodes(from source: IPv6, index: UInt32, cancel: CancelToken) {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var local = sockaddr_in6(source, port: 0, scope: source.isLinkLocal ? index : 0)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else { return }
        var interfaceIndex = index
        setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &interfaceIndex, socklen_t(MemoryLayout<UInt32>.size))

        var group = sockaddr_in6(IPv6("ff02::1")!, port: 0, scope: index)
        let identifier = UInt16(truncatingIfNeeded: getpid())
        for sequence in UInt16(0)..<2 {
            // Echo request; the kernel fills in the ICMPv6 checksum.
            let packet: [UInt8] = [128, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                                   UInt8(sequence >> 8), UInt8(sequence & 0xFF)] + Array("LanScan!".utf8)
            _ = packet.withUnsafeBytes { buffer in
                withUnsafePointer(to: &group) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
            // Replies only matter for populating the neighbor cache, so just drain them.
            let deadline = monotonicNanos() + 700_000_000
            var buffer = [UInt8](repeating: 0, count: 1500)
            while monotonicNanos() < deadline, !cancel.isCancelled {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 100) > 0 {
                    while recv(fd, &buffer, buffer.count, 0) > 0 {}
                }
            }
        }
    }

    struct Entry: Sendable {
        let ip: IPv6
        let mac: MACAddress
        let interfaceIndex: UInt32
    }

    /// The kernel's IPv6 neighbor cache, the same source `ndp -an` uses.
    static func read() -> [Entry] {
        RoutingTable.linkLayerEntries(family: AF_INET6) { address, mac, index in
            let sin6 = address.loadUnaligned(as: sockaddr_in6.self)
            guard sin6.sin6_family == sa_family_t(AF_INET6) else { return nil }
            return Entry(ip: IPv6(sin6.sin6_addr), mac: mac, interfaceIndex: index)
        }
    }
}

extension sockaddr_in6 {
    init(_ ip: IPv6, port: UInt16, scope: UInt32) {
        self.init()
        sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6_family = sa_family_t(AF_INET6)
        sin6_port = port.bigEndian
        sin6_addr = ip.in6Addr
        sin6_scope_id = scope
    }
}
