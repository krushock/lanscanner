import AppKit
import Observation
import UniformTypeIdentifiers

enum SidebarFilter: Hashable {
    case all, online, offline
    case category(DeviceCategory)
}

enum RangeMode: String {
    case automatic, custom
}

enum RangeError: Error, Equatable {
    case invalidStart, invalidEnd, reversed, tooLarge

    var message: String {
        switch self {
        case .invalidStart: "Enter a valid start address."
        case .invalidEnd: "Enter a valid end address."
        case .reversed: "The start address must come before the end address."
        case .tooLarge: "Ranges are limited to \(ScanModel.maxRangeSize.formatted()) addresses."
        }
    }
}

@MainActor
@Observable
final class ScanModel {
    enum VendorStatus: Equatable {
        case loading
        case ready
        case failed(String)
    }

    struct ScanSummary: Equatable {
        let found: Int
        let new: Int
    }

    private(set) var interfaces: [NetworkInterface] = []
    var selectedInterfaceID: String? {
        didSet { UserDefaults.standard.set(selectedInterfaceID, forKey: "selectedInterface") }
    }

    private(set) var devices: [Device.ID: Device] = [:]
    private(set) var phase: ScanPhase?
    private(set) var progress: Double = 0
    private(set) var lastSummary: ScanSummary?
    private(set) var lastScan: [String: Date] = [:]
    private(set) var needsLocalNetworkAccess = false
    private(set) var vendorStatus = VendorStatus.loading

    var filter = SidebarFilter.all
    var searchText = ""
    var selection = Set<Device.ID>()
    var showOffline: Bool {
        didSet { UserDefaults.standard.set(showOffline, forKey: "showOffline") }
    }

    // Scan options
    nonisolated static let maxRangeSize = 4096
    var rangeMode: RangeMode {
        didSet { UserDefaults.standard.set(rangeMode.rawValue, forKey: "rangeMode") }
    }
    var customRangeStart: String {
        didSet { UserDefaults.standard.set(customRangeStart, forKey: "rangeStart") }
    }
    var customRangeEnd: String {
        didSet { UserDefaults.standard.set(customRangeEnd, forKey: "rangeEnd") }
    }
    var includeIPv6: Bool {
        didSet { UserDefaults.standard.set(includeIPv6, forKey: "includeIPv6") }
    }
    /// Seconds between automatic rescans; 0 turns them off.
    var rescanInterval: Double {
        didSet {
            UserDefaults.standard.set(rescanInterval, forKey: "rescanInterval")
            scheduleRescans()
        }
    }
    private(set) var nextRescan: Date?

    private var scanTask: Task<Void, Never>?
    private var rescanTask: Task<Void, Never>?
    /// DHCP host names heard so far, by MAC, including devices not scanned yet.
    private var dhcpNames: [String: String] = [:]
    /// Names the user gave devices; kept separately so clearing the list doesn't lose them.
    private var customNames: [Device.ID: String] = [:]

    var isScanning: Bool { phase != nil }

    var selectedInterface: NetworkInterface? {
        interfaces.first { $0.id == selectedInterfaceID } ?? interfaces.first
    }

    /// Devices are remembered per network so switching Wi-Fi doesn't mix up lists.
    var networkID: String {
        guard let interface = selectedInterface else { return "" }
        return "\(interface.cidr)@\(interface.router?.description ?? "-")"
    }

    var networkDevices: [Device] {
        let id = networkID
        return devices.values.filter { $0.networkID == id }
    }

    var lastScanDate: Date? { lastScan[networkID] }

    /// The addresses the next scan will probe, or why the custom range is unusable.
    var scanRange: Result<ClosedRange<IPv4>, RangeError>? {
        guard let interface = selectedInterface else { return nil }
        switch rangeMode {
        case .automatic:
            return interface.hostRange.map { .success($0) }
        case .custom:
            guard let start = IPv4(customRangeStart.trimmingCharacters(in: .whitespaces)) else { return .failure(.invalidStart) }
            guard let end = IPv4(customRangeEnd.trimmingCharacters(in: .whitespaces)) else { return .failure(.invalidEnd) }
            guard start <= end else { return .failure(.reversed) }
            guard Int(end.raw - start.raw) < Self.maxRangeSize else { return .failure(.tooLarge) }
            return .success(start...end)
        }
    }

    var canScan: Bool {
        if case .success = scanRange { return true }
        return false
    }

    init() {
        let defaults = UserDefaults.standard
        showOffline = defaults.object(forKey: "showOffline") as? Bool ?? true
        selectedInterfaceID = defaults.string(forKey: "selectedInterface")
        rangeMode = RangeMode(rawValue: defaults.string(forKey: "rangeMode") ?? "") ?? .automatic
        customRangeStart = defaults.string(forKey: "rangeStart") ?? ""
        customRangeEnd = defaults.string(forKey: "rangeEnd") ?? ""
        includeIPv6 = defaults.object(forKey: "includeIPv6") as? Bool ?? true
        rescanInterval = defaults.double(forKey: "rescanInterval")
        loadDevices()
        refreshInterfaces()
        Task { await loadVendors() }
        Task { await listenForDHCP() }
        scheduleRescans()
    }

    private func scheduleRescans() {
        rescanTask?.cancel()
        nextRescan = nil
        let interval = rescanInterval
        guard interval > 0 else { return }
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.nextRescan = .now + interval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                if !isScanning { startScan() }
            }
        }
    }

    /// Fills the custom range with the selected network's host range.
    func resetCustomRange() {
        guard let range = selectedInterface?.hostRange else { return }
        customRangeStart = range.lowerBound.description
        customRangeEnd = range.upperBound.description
    }

    private func listenForDHCP() async {
        for await sighting in DHCPListener.sightings() {
            let id = sighting.mac.description
            if let hostname = sighting.hostname, dhcpNames[id] != hostname {
                dhcpNames[id] = hostname
                devices[id]?.identity.dhcpName = hostname
                saveDevices()
            }
            // A DHCP request proves the device is here, even if it ignores ARP and ping.
            if let ip = sighting.ip, let interface = selectedInterface, interface.contains(ip),
               ip != interface.address, sighting.mac != interface.visibleMAC {
                upsert(ip: ip, mac: sighting.mac, network: networkID, interface: interface)
                saveDevices()
            }
        }
    }

    // MARK: Filtering

    func visibleDevices(sortedBy order: [KeyPathComparator<Device>]) -> [Device] {
        var list = networkDevices
        if !showOffline, filter != .offline { list.removeAll { !$0.isOnline } }
        switch filter {
        case .all: break
        case .online: list.removeAll { !$0.isOnline }
        case .offline: list.removeAll(where: \.isOnline)
        case .category(let category): list.removeAll { $0.kind.category != category }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { device in
                ([device.displayName, device.ip.description, device.mac?.description, device.hostname,
                  device.vendor, device.modelDescription, device.kind.title] + (device.ipv6 ?? []).map(\.description))
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        return list.sorted(using: order)
    }

    func count(for filter: SidebarFilter) -> Int {
        let list = networkDevices.filter { showOffline || $0.isOnline || filter == .offline }
        switch filter {
        case .all: return list.count
        case .online: return list.count(where: \.isOnline)
        case .offline: return list.count { !$0.isOnline }
        case .category(let category): return list.count { $0.kind.category == category }
        }
    }

    // MARK: Interfaces

    func refreshInterfaces() {
        interfaces = NetworkInterface.current()
        if selectedInterfaceID == nil || !interfaces.contains(where: { $0.id == selectedInterfaceID }) {
            selectedInterfaceID = interfaces.first?.id
        }
    }

    // MARK: Scanning

    func toggleScan() {
        isScanning ? stopScan() : startScan()
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = nil
    }

    func startScan() {
        guard !isScanning else { return }
        refreshInterfaces()
        guard let interface = selectedInterface, case .success(let range) = scanRange else { return }
        let options = ScanOptions(range: range, includeIPv6: includeIPv6)

        let network = networkID
        let started = Date.now
        phase = .discovering
        progress = 0
        lastSummary = nil

        let me = upsert(ip: interface.address, mac: interface.visibleMAC, network: network, interface: interface)
        devices[me]?.isThisDevice = true
        devices[me]?.identity.friendlyName = SystemNetworkInfo.computerName
        devices[me]?.identity.mdnsName = SystemNetworkInfo.localHostName
        devices[me]?.ipv6 = includeIPv6 && !interface.ipv6Addresses.isEmpty ? interface.ipv6Addresses : nil

        scanTask = Task {
            var seen: Set<Device.ID> = [me]
            var byIP: [IPv4: Device.ID] = [interface.address: me]
            var replies: [IPv4: Double] = [:]
            var sawNeighbors = false

            for await event in NetworkScanner(interface: interface, options: options).events() {
                guard !Task.isCancelled else { break }
                switch event {
                case .progress(let value, let phase):
                    progress = value
                    self.phase = phase

                case .neighbors(let entries):
                    for entry in entries {
                        sawNeighbors = true
                        let id = upsert(ip: entry.ip, mac: entry.mac, network: network, interface: interface)
                        seen.insert(id)
                        byIP[entry.ip] = id
                        if let latency = replies[entry.ip] { devices[id]?.latency = latency }
                    }

                case .reply(let reply):
                    replies[reply.ip] = reply.milliseconds
                    if let id = byIP[reply.ip] { devices[id]?.latency = reply.milliseconds }

                case .identities(let identities):
                    // Hosts that answered ping but never showed up in the ARP cache (e.g. without
                    // Local Network access) are still worth listing, keyed by IP.
                    for (ip, latency) in replies where byIP[ip] == nil {
                        let id = upsert(ip: ip, mac: nil, network: network, interface: interface)
                        devices[id]?.latency = latency
                        seen.insert(id)
                        byIP[ip] = id
                    }
                    for (ip, identity) in identities {
                        let id = byIP[ip] ?? upsert(ip: ip, mac: nil, network: network, interface: interface)
                        seen.insert(id)
                        byIP[ip] = id
                        devices[id]?.identity.merge(identity)
                    }

                case .ipv6(let neighbors):
                    for (mac, addresses) in neighbors where mac != interface.visibleMAC {
                        devices[mac.description]?.ipv6 = addresses
                    }
                }
            }
            guard !Task.isCancelled else { return }
            finishScan(network: network, range: range, seen: seen, started: started,
                       blocked: !sawNeighbors && interface.visibleMAC == nil)
        }
    }

    private func finishScan(network: String, range: ClosedRange<IPv4>, seen: Set<Device.ID>, started: Date, blocked: Bool) {
        // Only devices inside the scanned range can be judged offline.
        // Anything heard since the scan began (a DHCP request, say) is still online.
        for (id, device) in devices where device.networkID == network && !seen.contains(id)
            && range.contains(device.ip) && device.lastSeen < started {
            devices[id]?.isOnline = false
            devices[id]?.latency = nil
        }
        let found = seen.count
        let new = devices.values.count { $0.networkID == network && $0.firstSeen >= started && !$0.isThisDevice }
        lastSummary = ScanSummary(found: found, new: new)
        lastScan[network] = .now
        needsLocalNetworkAccess = blocked
        phase = nil
        scanTask = nil
        saveDevices()
    }

    @discardableResult
    private func upsert(ip: IPv4, mac: MACAddress?, network: String, interface: NetworkInterface) -> Device.ID {
        let id = mac?.description ?? "ip-\(ip)"
        var device = devices[id] ?? Device(mac: mac, ip: ip, networkID: network)
        device.ip = ip
        device.networkID = network
        device.isOnline = true
        device.lastSeen = .now
        device.isGateway = ip == interface.router
        if let mac { device.vendor = VendorDatabase.shared.vendor(for: mac) ?? device.vendor }
        device.customName = customNames[id] ?? device.customName
        device.identity.dhcpName = dhcpNames[id] ?? device.identity.dhcpName
        devices[id] = device

        // A real MAC supersedes any placeholder entry that was keyed by this IP.
        if mac != nil { devices.removeValue(forKey: "ip-\(ip)") }
        return id
    }

    // MARK: Device actions

    func rename(_ id: Device.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        devices[id]?.customName = trimmed.isEmpty ? nil : trimmed
        customNames[id] = trimmed.isEmpty ? nil : trimmed
        saveDevices()
    }

    /// Empties the list for the current network. Custom names are kept for when devices reappear.
    func clearDevices() {
        stopScan()
        let network = networkID
        devices = devices.filter { $0.value.networkID != network }
        selection.removeAll()
        lastScan[network] = nil
        lastSummary = nil
        saveDevices()
    }

    func forget(_ ids: Set<Device.ID>) {
        for id in ids {
            devices.removeValue(forKey: id)
            customNames.removeValue(forKey: id)
        }
        selection.subtract(ids)
        saveDevices()
    }

    func forgetAll() {
        devices.removeAll()
        selection.removeAll()
        lastScan.removeAll()
        dhcpNames.removeAll()
        customNames.removeAll()
        saveDevices()
    }

    func wake(_ device: Device) -> Bool {
        guard let mac = device.mac, let interface = selectedInterface else { return false }
        return WakeOnLAN.wake(mac, broadcast: interface.broadcast)
    }

    // MARK: Export

    func exportCSV(_ list: [Device]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "LanScan \(Date.now.formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        func field(_ value: String?) -> String {
            let text = value ?? ""
            return text.contains(where: { ",\"\n".contains($0) }) ? "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" : text
        }
        var lines = ["Name,IP Address,MAC Address,Vendor,Hostname,Type,Model,Status,Latency (ms),Last Seen"]
        for device in list {
            lines.append([
                device.displayName, device.ip.description, device.mac?.description, device.vendor, device.hostname,
                device.kind.title, device.identity.model, device.isOnline ? "Online" : "Offline",
                device.latency.map { String(format: "%.1f", $0) }, device.lastSeen.formatted(.iso8601),
            ].map(field).joined(separator: ","))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Vendors

    func loadVendors(force: Bool = false) async {
        vendorStatus = .loading
        do {
            try await VendorDatabase.shared.load(force: force)
            vendorStatus = .ready
            for (id, device) in devices {
                if let mac = device.mac, let vendor = VendorDatabase.shared.vendor(for: mac) {
                    devices[id]?.vendor = vendor
                }
            }
        } catch {
            vendorStatus = VendorDatabase.shared.isLoaded ? .ready : .failed(error.localizedDescription)
        }
    }

    // MARK: Persistence

    private struct Archive: Codable {
        var devices: [Device]
        var lastScan: [String: Date]
        var dhcpNames: [String: String]?
        var customNames: [String: String]?
    }

    private static var archiveURL: URL {
        URL.applicationSupportDirectory.appending(components: "LanScan", "devices.json")
    }

    private func loadDevices() {
        guard let data = try? Data(contentsOf: Self.archiveURL),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        devices = Dictionary(archive.devices.map { device in
            var device = device
            device.isOnline = false
            device.latency = nil
            return (device.id, device)
        }, uniquingKeysWith: { first, _ in first })
        lastScan = archive.lastScan
        dhcpNames = archive.dhcpNames ?? [:]
        customNames = archive.customNames
            ?? Dictionary(uniqueKeysWithValues: devices.values.compactMap { device in device.customName.map { (device.id, $0) } })
    }

    private func saveDevices() {
        let archive = Archive(devices: Array(devices.values), lastScan: lastScan, dhcpNames: dhcpNames, customNames: customNames)
        let url = Self.archiveURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(archive).write(to: url, options: .atomic)
        }
    }
}

extension NetworkInterface {
    /// macOS reports 02:00:00:00:00:00 when the app may not see hardware addresses.
    var visibleMAC: MACAddress? {
        guard let macAddress, macAddress.description != "02:00:00:00:00:00" else { return nil }
        return macAddress
    }
}
