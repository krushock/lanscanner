import Foundation
import Dispatch

/// Passively learns the host names devices give the router (DHCP option 12, or the option 81 FQDN).
///
/// DISCOVER and REQUEST messages are broadcast to port 67 whenever a device joins or rebinds, so
/// every client on the segment, not only the router, can read them. Names arrive over time
/// while the app runs and are remembered per MAC address.
enum DHCPListener {
    struct Sighting: Sendable {
        let mac: MACAddress
        let hostname: String?
        /// The address the device holds or is confirming, from a REQUEST or INFORM.
        let ip: IPv4?
    }

    static func sightings() -> AsyncStream<Sighting> {
        AsyncStream { continuation in
            let cancel = CancelToken()
            continuation.onTermination = { _ in cancel.cancel() }
            DispatchQueue.global(qos: .utility).async {
                guard let socket = DatagramSocket(), socket.bindShared(port: 67) else {
                    continuation.finish()
                    return
                }
                while !cancel.isCancelled {
                    guard socket.wait(timeout: 1) else { continue }
                    while let datagram = socket.receive() {
                        if let sighting = parse(datagram.bytes) { continuation.yield(sighting) }
                    }
                }
                continuation.finish()
            }
        }
    }

    static func parse(_ bytes: [UInt8]) -> Sighting? {
        // BOOTREQUEST over Ethernet with a 6-byte hardware address and the DHCP magic cookie.
        guard bytes.count > 240, bytes[0] == 1, bytes[1] == 1, bytes[2] == 6,
              bytes[236 ..< 240].elementsEqual([99, 130, 83, 99]),
              let mac = MACAddress(bytes: Array(bytes[28 ..< 34])) else { return nil }

        var hostname: String?
        var fqdn: String?
        var messageType: UInt8?
        var requested: IPv4?
        var offset = 240
        while offset < bytes.count {
            let code = bytes[offset]
            if code == 0 { offset += 1; continue }
            if code == 255 { break }
            guard offset + 1 < bytes.count else { break }
            let length = Int(bytes[offset + 1])
            let start = offset + 2
            guard start + length <= bytes.count else { break }
            let value = bytes[start ..< start + length]
            switch code {
            case 12:
                hostname = String(decoding: value, as: UTF8.self)
            case 50 where length == 4:
                requested = IPv4(raw: value.reduce(0) { $0 << 8 | UInt32($1) })
            case 53 where length == 1:
                messageType = value.first
            case 81 where length > 3:
                // Flags, two legacy rcodes, then the name (plain ASCII or DNS wire format).
                let name = Array(value.dropFirst(3))
                if value[value.startIndex] & 0x04 != 0 {
                    var reader = DNSReader(bytes: name)
                    fqdn = reader.name()?.first
                } else {
                    fqdn = String(decoding: name, as: UTF8.self)
                }
            default:
                break
            }
            offset = start + length
        }

        let name = (hostname ?? fqdn)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let client = IPv4(raw: bytes[12 ..< 16].reduce(0) { $0 << 8 | UInt32($1) })
        // A DISCOVER only asks for an address, so its option 50 says nothing about what the device holds.
        let ip = messageType == 3 || messageType == 8 ? (client.raw != 0 ? client : requested) : nil
        let hostnameValue = name?.isEmpty == false ? name : nil
        guard hostnameValue != nil || ip != nil else { return nil }
        return Sighting(mac: mac, hostname: hostnameValue, ip: ip)
    }
}

extension DatagramSocket {
    /// Binds to `port` on all addresses, sharing it with other listeners.
    func bindShared(port: UInt16) -> Bool {
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, size)
        var address = sockaddr_in(IPv4(raw: 0), port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }
}
