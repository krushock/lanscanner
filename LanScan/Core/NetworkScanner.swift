import Dispatch
import Synchronization

enum ScanPhase: Sendable, Equatable {
    case discovering
    case resolving
}

enum ScanEvent: Sendable {
    case progress(Double, ScanPhase)
    case neighbors([ARPTable.Entry])
    case reply(Pinger.Reply)
    case identities([IPv4: HostIdentity])
    case ipv6([MACAddress: [IPv6]])
}

struct ScanOptions: Sendable {
    var range: ClosedRange<IPv4>
    var includeIPv6 = true
}

/// Discovers hosts on one interface: ping sweep → ARP cache → name resolution (+ IPv6 neighbors).
struct NetworkScanner: Sendable {
    let interface: NetworkInterface
    let options: ScanOptions

    func events() -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let cancel = CancelToken()
            continuation.onTermination = { _ in cancel.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                run(cancel: cancel) { continuation.yield($0) }
                continuation.finish()
            }
        }
    }

    private func run(cancel: CancelToken, emit: (ScanEvent) -> Void) {
        let index = interface.index
        let range = options.range
        func neighbors() -> [ARPTable.Entry] {
            ARPTable.read().filter { $0.interfaceIndex == index && range.contains($0.ip) }
        }

        emit(.progress(0, .discovering))
        emit(.neighbors(neighbors()))

        let targets = (range.lowerBound.raw...range.upperBound.raw)
            .lazy.filter { $0 != interface.address.raw }.map(IPv4.init(raw:))
        Pinger.sweep(
            Array(targets),
            cancel: cancel,
            progress: { emit(.progress($0 * 0.8, .discovering)) },
            tick: { emit(.neighbors(neighbors())) },
            reply: { emit(.reply($0)) }
        )
        guard !cancel.isCancelled else { return }

        let found = neighbors()
        emit(.neighbors(found))
        emit(.progress(0.85, .resolving))

        // IPv6 neighbor discovery runs alongside name resolution.
        let ipv6 = Mutex<[MACAddress: [IPv6]]>([:])
        let group = DispatchGroup()
        if options.includeIPv6 {
            let interface = interface
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let found = NeighborDiscovery.discover(on: interface, cancel: cancel)
                ipv6.withLock { $0 = found }
            }
        }

        var dnsServers = SystemNetworkInfo.load().dnsServers
        if let router = interface.router { dnsServers.insert(router, at: 0) }
        var seen = Set<IPv4>()
        dnsServers = dnsServers.filter { seen.insert($0).inserted }

        let hosts = found.map(\.ip) + [interface.address]
        let identities = NameResolver.resolve(hosts, on: interface.address, dnsServers: dnsServers, cancel: cancel)
            .filter { range.contains($0.key) }
        group.wait()
        guard !cancel.isCancelled else { return }

        // Hosts that answered Bonjour or UPnP but not ARP during the sweep are awake now, so try again.
        let known = Set(hosts)
        let late = identities.keys.filter { !known.contains($0) }
        if !late.isEmpty {
            Pinger.sweep(late, rounds: 1, listen: 0.6, cancel: cancel, progress: { _ in }, tick: {},
                         reply: { emit(.reply($0)) })
            emit(.neighbors(neighbors()))
        }
        guard !cancel.isCancelled else { return }
        emit(.identities(identities))
        emit(.ipv6(ipv6.withLock { $0 }))
        emit(.progress(1, .resolving))
    }
}
