import Darwin

/// ICMP echo sweep over an unprivileged `SOCK_DGRAM` ICMP socket.
///
/// Every request also makes the kernel ARP for the target, so hosts that ignore ping
/// still land in the ARP cache that `ARPTable` reads afterwards.
enum Pinger {
    struct Reply: Sendable {
        let ip: IPv4
        let milliseconds: Double
    }

    static func sweep(
        _ targets: [IPv4],
        rounds: Int = 3,
        listen: Double = 1.1,
        cancel: CancelToken,
        progress: (Double) -> Void,
        tick: () -> Void,
        reply: (Reply) -> Void
    ) {
        guard !targets.isEmpty else { return }
        let icmpSocket = DatagramSocket(protocol: IPPROTO_ICMP)
        let isICMP = icmpSocket != nil
        guard let socket = icmpSocket ?? DatagramSocket() else { return }

        let identifier = UInt16(truncatingIfNeeded: getpid())
        var sentAt: [UInt32: UInt64] = [:]
        var answered: Set<UInt32> = []
        var lastTick = monotonicNanos()

        func handle(_ from: IPv4, _ bytes: [UInt8]) {
            guard let start = sentAt[from.raw], !answered.contains(from.raw), isEchoReply(bytes) else { return }
            answered.insert(from.raw)
            reply(Reply(ip: from, milliseconds: Double(monotonicNanos() - start) / 1e6))
        }

        func maybeTick() {
            let now = monotonicNanos()
            if now - lastTick > 400_000_000 { lastTick = now; tick() }
        }

        var pending = targets
        for round in 0..<rounds where !pending.isEmpty {
            for (index, ip) in pending.enumerated() {
                if cancel.isCancelled { return }
                let sequence = UInt16(truncatingIfNeeded: index)
                if isICMP {
                    socket.send(echoRequest(identifier: identifier, sequence: sequence), to: ip, port: 0)
                } else {
                    // Without an ICMP socket, a UDP datagram to the discard port still triggers ARP.
                    socket.send([0], to: ip, port: 9)
                }
                sentAt[ip.raw] = monotonicNanos()
                if index % 8 == 7 {
                    while let datagram = socket.receive() { handle(datagram.from, datagram.bytes) }
                    progress((Double(round) + Double(index + 1) / Double(pending.count)) / Double(rounds))
                    maybeTick()
                    usleep(4_000)
                }
            }
            let deadline = monotonicNanos() + UInt64(listen * 1e9)
            while monotonicNanos() < deadline, !cancel.isCancelled {
                socket.collect(until: min(deadline, monotonicNanos() + 400_000_000), cancel: cancel, handler: handle)
                maybeTick()
            }
            progress(Double(round + 1) / Double(rounds))
            pending.removeAll { answered.contains($0.raw) }
        }
    }

    private static func echoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        packet += Array("LanScan!".utf8)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// macOS includes the IP header on datagram ICMP sockets; skip it when present.
    private static func isEchoReply(_ bytes: [UInt8]) -> Bool {
        guard let first = bytes.first else { return false }
        var offset = 0
        if first >> 4 == 4 { offset = Int(first & 0x0F) * 4 }
        return bytes.count > offset && bytes[offset] == 0
    }
}
