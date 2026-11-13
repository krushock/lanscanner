import Darwin
import Dispatch
import Synchronization

/// A thread-safe flag that background socket loops check between steps.
final class CancelToken: Sendable {
    private let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .relaxed) }
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// Runs blocking socket work on a global queue so it never ties up the cooperative thread pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

func monotonicNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

extension sockaddr_in {
    init(_ ip: IPv4, port: UInt16) {
        self.init()
        sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin_family = sa_family_t(AF_INET)
        sin_port = port.bigEndian
        sin_addr = ip.inAddr
    }
}

/// A non-blocking IPv4 datagram socket.
final class DatagramSocket {
    let fd: Int32

    init?(protocol proto: Int32 = IPPROTO_UDP, broadcast: Bool = false) {
        fd = socket(AF_INET, SOCK_DGRAM, proto)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var size: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        if broadcast {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    deinit { close(fd) }

    @discardableResult
    func send(_ bytes: [UInt8], to ip: IPv4, port: UInt16) -> Bool {
        var address = sockaddr_in(ip, port: port)
        return bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } >= 0
    }

    /// Returns one pending datagram, or nil when the queue is empty.
    func receive() -> (from: IPv4, bytes: [UInt8])? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var address = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &addressLength)
                }
            }
        }
        guard count > 0 else { return nil }
        return (IPv4(address.sin_addr), Array(buffer[..<count]))
    }

    /// Waits up to `timeout` seconds for the socket to become readable.
    func wait(timeout: Double) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, Int32(max(0, timeout) * 1000)) > 0
    }

    /// Drains replies until `deadline` (monotonic nanoseconds), handing each to `handler`.
    func collect(until deadline: UInt64, cancel: CancelToken, handler: (IPv4, [UInt8]) -> Void) {
        while !cancel.isCancelled {
            let now = monotonicNanos()
            guard now < deadline else { return }
            guard wait(timeout: min(0.1, Double(deadline - now) / 1e9)) else { continue }
            while let datagram = receive() { handler(datagram.from, datagram.bytes) }
        }
    }
}

/// Sends a batch of UDP queries from one socket and gathers every reply.
enum UDPBatch {
    struct Query: Sendable {
        let host: IPv4
        let port: UInt16
        let payload: [UInt8]
    }

    static func exchange(_ queries: [Query], listen: Double, cancel: CancelToken) -> [(from: IPv4, bytes: [UInt8])] {
        guard !queries.isEmpty, let socket = DatagramSocket() else { return [] }
        var replies: [(from: IPv4, bytes: [UInt8])] = []
        for (index, query) in queries.enumerated() {
            if cancel.isCancelled { return replies }
            socket.send(query.payload, to: query.host, port: query.port)
            if index % 16 == 15 {
                while let reply = socket.receive() { replies.append(reply) }
                usleep(2_000)
            }
        }
        socket.collect(until: monotonicNanos() + UInt64(listen * 1e9), cancel: cancel) { replies.append(($0, $1)) }
        return replies
    }
}

enum WakeOnLAN {
    /// Broadcasts a magic packet (6 × 0xFF followed by the MAC repeated 16 times).
    static func wake(_ mac: MACAddress, broadcast: IPv4) -> Bool {
        guard let socket = DatagramSocket(broadcast: true) else { return false }
        let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: mac.bytes, count: 16).joined())
        let sentDirected = socket.send(packet, to: broadcast, port: 9)
        let sentGlobal = socket.send(packet, to: IPv4(raw: 0xFFFF_FFFF), port: 9)
        return sentDirected || sentGlobal
    }
}

extension DatagramSocket {
    static let mdnsGroup = IPv4(raw: 0xE000_00FB) // 224.0.0.251

    /// A socket that joins the mDNS group on `interface`, sharing port 5353 with mDNSResponder,
    /// so it hears the multicast answers that many embedded devices send instead of unicast ones.
    static func multicastDNS(on interface: IPv4) -> DatagramSocket? {
        guard let socket = DatagramSocket() else { return nil }
        var on: Int32 = 1
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(socket.fd, SOL_SOCKET, SO_REUSEADDR, &on, intSize)
        setsockopt(socket.fd, SOL_SOCKET, SO_REUSEPORT, &on, intSize)

        var address = sockaddr_in(IPv4(raw: 0), port: 5353)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var membership = ip_mreq(imr_multiaddr: mdnsGroup.inAddr, imr_interface: interface.inAddr)
        guard setsockopt(socket.fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
            return nil
        }
        var outgoing = interface.inAddr
        setsockopt(socket.fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size))
        var ttl: UInt8 = 255
        setsockopt(socket.fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1)
        return socket
    }
}
