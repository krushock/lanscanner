import Darwin

/// Reads the kernel's ARP cache through the routing sysctl, the same source `arp -an` uses.
enum ARPTable {
    struct Entry: Hashable, Sendable {
        let ip: IPv4
        let mac: MACAddress
        let interfaceIndex: UInt32
    }

    static func read() -> [Entry] {
        RoutingTable.linkLayerEntries(family: AF_INET) { address, mac, index in
            let sin = address.loadUnaligned(as: sockaddr_in.self)
            guard sin.sin_family == sa_family_t(AF_INET) else { return nil }
            return Entry(ip: IPv4(sin.sin_addr), mac: mac, interfaceIndex: index)
        }
    }
}

/// Link-layer (ARP / NDP) entries from the routing table: each is a destination sockaddr
/// followed by the `sockaddr_dl` holding the neighbor's MAC address.
enum RoutingTable {
    static func linkLayerEntries<Entry>(
        family: Int32,
        parse: (_ destination: UnsafeRawPointer, _ mac: MACAddress, _ interfaceIndex: UInt32) -> Entry?
    ) -> [Entry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_LLINFO]
        var buffer: [UInt8] = []
        var length = 0

        // The table can grow between the size query and the read, so retry with headroom.
        for _ in 0..<4 {
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return [] }
            if length == 0 { return [] }
            length += length / 2
            buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 { break }
            guard errno == ENOMEM else { return [] }
            buffer = []
        }
        guard !buffer.isEmpty else { return [] }

        var entries: [Entry] = []
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let headerSize = MemoryLayout<rt_msghdr>.size
            while offset + headerSize <= length {
                let header = (base + offset).loadUnaligned(as: rt_msghdr.self)
                let messageLength = Int(header.rtm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                let destination = base + offset + headerSize
                let destinationLength = Int(destination.load(as: UInt8.self))
                let rounded = destinationLength > 0
                    ? 1 + ((destinationLength - 1) | (MemoryLayout<UInt32>.size - 1)) : MemoryLayout<UInt32>.size
                let sdlPointer = destination + rounded
                guard sdlPointer + MemoryLayout<sockaddr_dl>.size <= base + offset + messageLength,
                      let mac = MACAddress(sockaddrDL: sdlPointer),
                      !mac.isBroadcast, !mac.isMulticast, !mac.isZero else { continue }
                let sdl = sdlPointer.loadUnaligned(as: sockaddr_dl.self)
                if let entry = parse(destination, mac, UInt32(sdl.sdl_index)) { entries.append(entry) }
            }
        }
        return entries
    }
}
