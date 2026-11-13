import Foundation
import Synchronization

/// Everything we managed to learn about a host beyond its addresses.
struct HostIdentity: Sendable, Hashable, Codable {
    var mdnsName: String?
    var dnsName: String?
    var netbiosName: String?
    var friendlyName: String?
    var model: String?
    var services: [String] = []
    var upnpName: String?
    var upnpModel: String?
    /// The name the device sent the router in its DHCP request.
    var dhcpName: String?

    var isEmpty: Bool { self == HostIdentity() }
}

/// Resolves names with three batched UDP passes that run side by side:
/// unicast mDNS straight to each host, NetBIOS node status, and reverse DNS against local resolvers.
enum NameResolver {
    static func resolve(_ hosts: [IPv4], on interface: IPv4, dnsServers: [IPv4], cancel: CancelToken) -> [IPv4: HostIdentity] {
        let results = Mutex<[IPv4: HostIdentity]>([:])
        let group = DispatchGroup()

        func run(_ work: @escaping @Sendable () -> [IPv4: HostIdentity]) {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let found = work()
                results.withLock { all in
                    for (ip, identity) in found { all[ip, default: HostIdentity()].merge(identity) }
                }
            }
        }

        run { mdns(hosts, on: interface, cancel: cancel) }
        run { netbios(hosts, cancel: cancel).mapValues { HostIdentity(netbiosName: $0) } }
        run { reverseDNS(hosts, servers: dnsServers, cancel: cancel).mapValues { HostIdentity(dnsName: $0) } }
        run {
            SSDP.discover(on: interface, cancel: cancel).mapValues {
                HostIdentity(upnpName: $0.friendlyName, upnpModel: $0.model)
            }
        }
        group.wait()

        return results.withLock { $0 }
    }

    // MARK: mDNS

    private static let local = "local"
    private static let deviceInfo = "_device-info._tcp"
    private static let serviceEnumeration = ["_services", "_dns-sd", "_udp", local]
    /// Services whose instance names or TXT records tell us what a device is called or what model it is.
    private static let descriptiveServices: Set<String> = [
        "_companion-link._tcp", "_airplay._tcp", "_raop._tcp", "_googlecast._tcp", "_hap._tcp",
        "_ipp._tcp", "_printer._tcp", "_spotify-connect._tcp", "_sonos._tcp", "_smb._tcp", "_rfb._tcp",
    ]

    private static func mdns(_ hosts: [IPv4], on interface: IPv4, cancel: CancelToken) -> [IPv4: HostIdentity] {
        var discovered: [IPv4: MDNSFindings] = [:]

        // Many embedded devices only answer multicast queries, so browse the whole network alongside.
        let multicast = Mutex<[IPv4: [DNSRecord]]>([:])
        let browsing = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: browsing) {
            let found = browse(on: interface, cancel: cancel)
            multicast.withLock { $0 = found }
        }

        func absorb(_ replies: [(from: IPv4, bytes: [UInt8])]) {
            for reply in replies {
                guard let message = DNSMessage(reply.bytes) else { continue }
                discovered[reply.from, default: MDNSFindings()].absorb(message.records)
            }
        }

        let first = hosts.flatMap { host in
            [
                DNSMessage.query(id: 1, name: host.reverseLabels, type: DNSType.ptr),
                DNSMessage.query(id: 2, name: deviceInfo.labels + [local], type: DNSType.ptr),
                DNSMessage.query(id: 3, name: serviceEnumeration, type: DNSType.ptr),
            ].map { UDPBatch.Query(host: host, port: 5353, payload: $0) }
        }
        absorb(UDPBatch.exchange(first, listen: 1.2, cancel: cancel))

        // Second pass: ask responsive hosts about the services they advertised.
        let followUps = discovered.flatMap { host, findings -> [UDPBatch.Query] in
            var queries = findings.services.intersection(descriptiveServices).sorted().prefix(6).map {
                DNSMessage.query(id: 4, name: $0.labels + [local], type: DNSType.ptr)
            }
            if findings.txt[deviceInfo] == nil, let instance = findings.instances[deviceInfo] {
                queries.append(DNSMessage.query(id: 5, name: [instance] + deviceInfo.labels + [local], type: DNSType.txt))
            }
            return queries.map { UDPBatch.Query(host: host, port: 5353, payload: $0) }
        }
        if !followUps.isEmpty, !cancel.isCancelled {
            absorb(UDPBatch.exchange(followUps, listen: 0.8, cancel: cancel))
        }

        browsing.wait()
        // Includes hosts missing from the ARP cache: answering here proves they're awake.
        for (host, records) in multicast.withLock({ $0 }) {
            discovered[host, default: MDNSFindings()].absorb(records)
        }
        return discovered.mapValues(\.identity).filter { !$0.value.isEmpty }
    }

    /// Multicast service browse: enumerate service types, then ask for every instance of each.
    /// Answers are attributed to the address in their A record (so sleep proxies don't steal them),
    /// falling back to the sender.
    private static func browse(on interface: IPv4, cancel: CancelToken) -> [IPv4: [DNSRecord]] {
        guard let socket = DatagramSocket.multicastDNS(on: interface) else { return [:] }
        var records: [IPv4: [DNSRecord]] = [:]
        var types = Set<String>()

        func handle(_ from: IPv4, _ bytes: [UInt8]) {
            guard let message = DNSMessage(bytes) else { return }
            let addresses = Set(message.records.compactMap { record -> IPv4? in
                if case .a(let ip) = record.data { return ip }
                return nil
            })
            let owner = addresses.count == 1 ? addresses.first! : from
            records[owner, default: []].append(contentsOf: message.records)
            for record in message.records {
                if case .ptr(let target) = record.data,
                   record.name.map({ $0.lowercased() }) == serviceEnumeration, target.count >= 2 {
                    types.insert(target.prefix(2).joined(separator: "."))
                }
            }
        }

        socket.send(DNSMessage.query(id: 0, name: serviceEnumeration, type: DNSType.ptr), to: DatagramSocket.mdnsGroup, port: 5353)
        socket.collect(until: monotonicNanos() + 1_200_000_000, cancel: cancel, handler: handle)

        for type in types.sorted() where !cancel.isCancelled {
            socket.send(DNSMessage.query(id: 0, name: type.labels + [local], type: DNSType.ptr), to: DatagramSocket.mdnsGroup, port: 5353)
            while let datagram = socket.receive() { handle(datagram.from, datagram.bytes) }
            usleep(3_000)
        }
        socket.collect(until: monotonicNanos() + 1_500_000_000, cancel: cancel, handler: handle)
        return records
    }

    // MARK: NetBIOS

    private static func netbios(_ hosts: [IPv4], cancel: CancelToken) -> [IPv4: String] {
        // Node status request for the wildcard name "*", first-level encoded.
        let wildcard = "CK" + String(repeating: "A", count: 30)
        let queries = hosts.map {
            UDPBatch.Query(host: $0, port: 137, payload: DNSMessage.query(id: 0x4C53, name: [wildcard], type: DNSType.nbstat))
        }
        var names: [IPv4: String] = [:]
        for reply in UDPBatch.exchange(queries, listen: 1.0, cancel: cancel) {
            if let name = parseNodeStatus(reply.bytes) { names[reply.from] = name }
        }
        return names
    }

    private static func parseNodeStatus(_ bytes: [UInt8]) -> String? {
        var reader = DNSReader(bytes: bytes)
        reader.offset = 12
        guard reader.name() != nil, reader.u16() == DNSType.nbstat, reader.u16() != nil, reader.u32() != nil,
              reader.u16() != nil, let count = reader.u8() else { return nil }
        var fallback: String?
        for _ in 0..<count {
            guard reader.offset + 18 <= bytes.count else { break }
            let raw = bytes[reader.offset ..< reader.offset + 15]
            let suffix = bytes[reader.offset + 15]
            let isGroup = bytes[reader.offset + 16] & 0x80 != 0
            reader.offset += 18
            let name = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !name.isEmpty, !isGroup else { continue }
            if suffix == 0x00 { return name }
            if suffix == 0x20 { fallback = fallback ?? name }
        }
        return fallback
    }

    // MARK: Reverse DNS

    private static func reverseDNS(_ hosts: [IPv4], servers: [IPv4], cancel: CancelToken) -> [IPv4: String] {
        // Only ask resolvers on private networks; public ones know nothing about LAN addresses.
        let local = servers.filter(\.isPrivate)
        guard !local.isEmpty, hosts.count < 0xFFFF else { return [:] }
        let queries = local.flatMap { server in
            hosts.enumerated().map { index, host in
                UDPBatch.Query(host: server, port: 53, payload: DNSMessage.query(
                    id: UInt16(index), name: host.reverseLabels, type: DNSType.ptr, recursionDesired: true))
            }
        }
        var names: [IPv4: String] = [:]
        for reply in UDPBatch.exchange(queries, listen: 1.0, cancel: cancel) {
            guard let message = DNSMessage(reply.bytes), Int(message.id) < hosts.count else { continue }
            for record in message.records {
                if case .ptr(let target) = record.data, !target.isEmpty {
                    names[hosts[Int(message.id)]] = names[hosts[Int(message.id)]] ?? target.hostName
                }
            }
        }
        return names
    }
}

/// Accumulates mDNS records from one host across both query passes.
private struct MDNSFindings {
    var reverseName: String?
    var srvTarget: String?
    var services: Set<String> = []
    var instances: [String: String] = [:]
    var txt: [String: [String: String]] = [:]

    mutating func absorb(_ records: [DNSRecord]) {
        for record in records {
            let name = record.name.map { $0.lowercased() }
            switch record.data {
            case .ptr(let target) where name.suffix(2) == ["in-addr", "arpa"]:
                reverseName = reverseName ?? target.hostName
            case .ptr(let target) where name == ["_services", "_dns-sd", "_udp", "local"]:
                if target.count >= 2 { services.insert(target.prefix(2).joined(separator: ".").lowercased()) }
            case .ptr(let target) where name.count == 3 && name[0].hasPrefix("_"):
                let service = name.prefix(2).joined(separator: ".")
                services.insert(service)
                if let instance = target.first { instances[service] = instances[service] ?? instance }
            case .txt(let strings) where name.count >= 4 && name[1].hasPrefix("_"):
                let service = name[1...2].joined(separator: ".")
                instances[service] = instances[service] ?? record.name[0]
                var values: [String: String] = [:]
                for string in strings {
                    let parts = string.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 { values[parts[0].lowercased()] = String(parts[1]) }
                }
                txt[service, default: [:]].merge(values) { old, _ in old }
            case .srv(_, let target) where target.last?.lowercased() == "local":
                srvTarget = srvTarget ?? target.hostName
            default:
                break
            }
        }
    }

    var identity: HostIdentity {
        var identity = HostIdentity()
        identity.mdnsName = reverseName ?? srvTarget

        let friendly = [
            instances["_device-info._tcp"],
            instances["_companion-link._tcp"],
            txt["_googlecast._tcp"]?["fn"],
            instances["_airplay._tcp"],
            instances["_raop._tcp"].map { $0.split(separator: "@", maxSplits: 1).last.map(String.init) ?? $0 },
            instances["_hap._tcp"],
            instances["_ipp._tcp"] ?? instances["_printer._tcp"],
            instances["_sonos._tcp"],
        ]
        identity.friendlyName = friendly.compactMap { $0 }.first { !$0.isEmpty }

        let models = [
            txt["_device-info._tcp"]?["model"],
            txt["_airplay._tcp"]?["model"],
            txt["_raop._tcp"]?["am"],
            txt["_googlecast._tcp"]?["md"],
            txt["_companion-link._tcp"]?["rpmd"],
            txt["_hap._tcp"]?["md"],
            txt["_ipp._tcp"]?["ty"],
        ]
        let anyModel = txt.keys.sorted().lazy.compactMap { self.txt[$0]?["model"] ?? self.txt[$0]?["md"] }.first
        identity.model = (models + [anyModel]).compactMap { $0 }.first { !$0.isEmpty }
        identity.services = services.subtracting(["_device-info._tcp"]).sorted()
        return identity
    }
}

extension HostIdentity {
    mutating func merge(_ other: HostIdentity) {
        mdnsName = other.mdnsName ?? mdnsName
        dnsName = other.dnsName ?? dnsName
        netbiosName = other.netbiosName ?? netbiosName
        friendlyName = other.friendlyName ?? friendlyName
        model = other.model ?? model
        if !other.services.isEmpty { services = other.services }
        upnpName = other.upnpName ?? upnpName
        upnpModel = other.upnpModel ?? upnpModel
        dhcpName = other.dhcpName ?? dhcpName
    }
}

extension IPv4 {
    var isPrivate: Bool {
        raw >> 24 == 10 || raw >> 20 == 0xAC1 || raw >> 16 == 0xC0A8 || raw >> 22 == 0x191 // 100.64/10
    }
}

private extension String {
    var labels: [String] { split(separator: ".").map(String.init) }
}
