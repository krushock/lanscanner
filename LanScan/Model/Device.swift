import IOKit.ps
import SwiftUI

struct Device: Identifiable, Hashable, Codable, Sendable {
    /// The MAC address when known; hosts seen only by ping are keyed by IP.
    let id: String
    var mac: MACAddress?
    var ip: IPv4
    var networkID: String
    var identity = HostIdentity()
    var vendor: String?
    var customName: String?
    var latency: Double?
    var ipv6: [IPv6]?
    var isOnline = true
    var isGateway = false
    var isThisDevice = false
    var firstSeen = Date.now
    var lastSeen = Date.now

    init(mac: MACAddress?, ip: IPv4, networkID: String) {
        self.id = mac?.description ?? "ip-\(ip)"
        self.mac = mac
        self.ip = ip
        self.networkID = networkID
    }

    var hostname: String? { identity.dhcpName ?? identity.mdnsName ?? identity.dnsName ?? identity.netbiosName }

    /// The first catalog rule that recognises this device, if any.
    var catalogMatch: DeviceCatalog.Match? { DeviceCatalog.shared.match(self) }

    /// Apple's marketing name, then a catalog product, then whatever model string the device reported.
    var modelDescription: String? {
        if let model = identity.model, let apple = DeviceCatalog.shared.appleProduct(model) { return apple }
        return catalogMatch?.product ?? identity.model.map(ModelNames.friendly) ?? identity.upnpModel
    }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if let friendly = identity.friendlyName ?? identity.upnpName { return friendly }
        let hosts = [identity.dhcpName, identity.mdnsName, identity.netbiosName, identity.dnsName].compactMap { $0 }
        if let host = hosts.first(where: { !$0.looksMachineGenerated }) { return host.prettyHostName }
        if let product = catalogMatch?.product { return product }
        if let host = hosts.first { return host.prettyHostName }
        if isGateway { return "Router" }
        if let vendor { return "\(vendor.shortVendor) Device" }
        if mac?.isLocallyAdministered == true { return "Private Device" }
        return ip.description
    }

    var vendorDescription: String {
        if let vendor { return vendor }
        if mac?.isLocallyAdministered == true { return "Private Address" }
        return mac == nil ? "—" : "Unknown"
    }

    var kind: DeviceKind { DeviceKind.classify(self) }

    // Non-optional keys for table sorting.
    var macSortKey: String { mac?.description ?? "" }
    var ipv6SortKey: String { ipv6?.first?.description ?? "" }
    var hostnameSortKey: String { hostname ?? "" }
    var latencySortKey: Double { latency ?? .infinity }
    var onlineSortKey: Int { isOnline ? 0 : 1 }
}

enum DeviceCategory: String, CaseIterable, Identifiable, Sendable {
    case computers, mobile, network, media, smartHome, printers, other

    var id: Self { self }

    var title: String {
        switch self {
        case .computers: "Computers"
        case .mobile: "Phones & Tablets"
        case .network: "Network"
        case .media: "Media & Entertainment"
        case .smartHome: "Smart Home"
        case .printers: "Printers"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .computers: "laptopcomputer"
        case .mobile: "iphone"
        case .network: "wifi.router"
        case .media: "tv"
        case .smartHome: "homekit"
        case .printers: "printer"
        case .other: "questionmark.circle"
        }
    }
}

enum DeviceKind: String, Sendable, Decodable {
    case router, laptop, desktop, server, raspberryPi, phone, tablet, watch
    case tv, speaker, console, printer, camera, nas, smartHome, light, vacuum, evCharger, energy, unknown

    var title: String {
        switch self {
        case .router: "Router"
        case .laptop: "Laptop"
        case .desktop: "Computer"
        case .server: "Server"
        case .raspberryPi: "Single-Board Computer"
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .watch: "Watch"
        case .tv: "TV & Streaming"
        case .speaker: "Speaker"
        case .console: "Game Console"
        case .printer: "Printer"
        case .camera: "Camera"
        case .nas: "Network Storage"
        case .smartHome: "Smart Home Device"
        case .light: "Light"
        case .vacuum: "Robot Vacuum"
        case .evCharger: "EV Charger"
        case .energy: "Energy"
        case .unknown: "Device"
        }
    }

    var symbol: String {
        switch self {
        case .router: "wifi.router"
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .server: "server.rack"
        case .raspberryPi: "cpu"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .watch: "applewatch"
        case .tv: "tv"
        case .speaker: "hifispeaker"
        case .console: "gamecontroller"
        case .printer: "printer"
        case .camera: "web.camera"
        case .nas: "externaldrive.connected.to.line.below"
        case .smartHome: "homekit"
        case .light: "lightbulb"
        case .vacuum: "robotic.vacuum"
        case .evCharger: "ev.charger"
        case .energy: "bolt.batteryblock"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .router: .teal
        case .laptop, .desktop: .blue
        case .server, .nas: .indigo
        case .raspberryPi: .pink
        case .phone, .tablet, .watch: .orange
        case .tv, .console: .purple
        case .speaker: .mint
        case .printer: .brown
        case .camera: .red
        case .smartHome, .light: .yellow
        case .vacuum: .cyan
        case .evCharger, .energy: .green
        case .unknown: .gray
        }
    }

    var category: DeviceCategory {
        switch self {
        case .laptop, .desktop, .server, .raspberryPi: .computers
        case .phone, .tablet, .watch: .mobile
        case .router, .nas: .network
        case .tv, .speaker, .console: .media
        case .smartHome, .camera, .light, .vacuum, .evCharger, .energy: .smartHome
        case .printer: .printers
        case .unknown: .other
        }
    }

    /// Best guess from (in order) role, Apple model, the device catalog, Bonjour model,
    /// advertised services, host names, then vendor.
    static func classify(_ device: Device) -> DeviceKind {
        if device.isGateway { return .router }
        if device.isThisDevice { return ThisMac.isLaptop ? .laptop : .desktop }

        if let identifier = device.identity.model, let apple = DeviceCatalog.shared.appleProduct(identifier),
           let kind = fromModel(apple.lowercased().filter { !$0.isWhitespace }) { return kind }
        if let kind = device.catalogMatch?.kind { return kind }

        let model = device.identity.model?.lowercased() ?? ""
        if let kind = fromModel(model) { return kind }

        let services = Set(device.identity.services)
        if !services.isDisjoint(with: ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp", "_uscan._tcp"]) { return .printer }
        if !services.isDisjoint(with: ["_googlecast._tcp", "_androidtvremote2._tcp", "_amzn-wplay._tcp"]) { return .tv }
        if services.contains("_hap._tcp") { return .smartHome }
        if !services.isDisjoint(with: ["_sonos._tcp", "_spotify-connect._tcp"]) { return .speaker }

        let names = [device.identity.friendlyName, device.identity.upnpName, device.identity.upnpModel, device.identity.dhcpName,
                     device.identity.mdnsName, device.identity.netbiosName, device.identity.dnsName]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        if let kind = fromName(names) { return kind }
        // Apple-silicon Macs report generic identifiers like "Mac17,4"; most of those are laptops.
        if model.hasPrefix("mac") { return .laptop }

        let vendor = device.vendor?.lowercased() ?? ""
        if let kind = fromVendor(vendor) { return kind }

        if services.contains("_airplay._tcp") { return .tv }
        if !services.isDisjoint(with: ["_smb._tcp", "_afpovertcp._tcp", "_ssh._tcp", "_rfb._tcp"]) { return .desktop }
        if device.mac?.isLocallyAdministered == true { return .phone }
        return .unknown
    }

    private static func fromModel(_ model: String) -> DeviceKind? {
        guard !model.isEmpty else { return nil }
        let rules: [(String, DeviceKind)] = [
            ("macbook", .laptop), ("imac", .desktop), ("macmini", .desktop), ("macpro", .desktop),
            ("macstudio", .desktop), ("iphone", .phone), ("ipad", .tablet),
            ("watch", .watch), ("appletv", .tv), ("audioaccessory", .speaker), ("homepod", .speaker),
            ("chromecast", .tv), ("google tv", .tv), ("nest", .speaker), ("google home", .speaker),
        ]
        return rules.first { model.hasPrefix($0.0) || model.contains($0.0) }?.1
    }

    private static func fromName(_ name: String) -> DeviceKind? {
        guard !name.isEmpty else { return nil }
        let rules: [([String], DeviceKind)] = [
            (["iphone", "android", "galaxy", "pixel", "oneplus", "xiaomi", "redmi", "huawei", "phone"], .phone),
            (["ipad", "tablet", "kindle"], .tablet),
            (["watch"], .watch),
            (["macbook", "laptop", "notebook", "thinkpad"], .laptop),
            (["imac", "mac-mini", "macmini", "mac-studio", "desktop", "-pc", "workstation"], .desktop),
            (["appletv", "apple-tv", "roku", "chromecast", "firetv", "fire-tv", "shield", "bravia", "tv"], .tv),
            (["homepod", "sonos", "echo", "alexa", "speaker", "nest-audio", "google-home", "nest-mini"], .speaker),
            (["playstation", "ps4", "ps5", "xbox", "nintendo", "switch"], .console),
            (["printer", "epson", "brother", "canon", "laserjet", "officejet", "deskjet"], .printer),
            (["camera", "doorbell", "arlo", "wyze", "-cam"], .camera),
            (["synology", "diskstation", "qnap", "nas"], .nas),
            (["raspberrypi", "raspberry"], .raspberryPi),
            (["esp", "tasmota", "shelly", "tuya", "hue", "lifx", "plug", "bulb", "thermostat", "ecobee", "smart"], .smartHome),
            (["server", "proxmox", "ubuntu", "debian"], .server),
            (["router", "gateway", "unifi", "eero", "orbi", "deco", "access-point"], .router),
        ]
        return rules.first { $0.0.contains { name.contains($0) } }?.1
    }

    private static func fromVendor(_ vendor: String) -> DeviceKind? {
        guard !vendor.isEmpty else { return nil }
        let rules: [([String], DeviceKind)] = [
            (["raspberry"], .raspberryPi),
            (["espressif", "tuya", "shelly", "signify", "lifx", "ecobee", "nest labs", "wiz", "meross", "lumi united"], .smartHome),
            (["sonos", "bose", "harman"], .speaker),
            (["roku", "vizio", "tcl", "hisense", "nvidia"], .tv),
            (["nintendo", "sony interactive"], .console),
            (["synology", "qnap", "western digital", "buffalo"], .nas),
            (["seiko epson", "brother", "canon", "xerox", "lexmark", "hp inc", "kyocera", "ricoh"], .printer),
            (["hikvision", "dahua", "reolink", "amcrest", "axis comm", "wyze"], .camera),
            (["ubiquiti", "netgear", "eero", "cisco", "aruba", "mikrotik", "linksys", "tp-link", "zyxel", "sagemcom", "arris", "technicolor", "avm", "huawei device"], .router),
            (["intel", "realtek", "dell", "lenovo", "micro-star", "asrock", "gigabyte", "hewlett packard"], .desktop),
        ]
        return rules.first { $0.0.contains { vendor.contains($0) } }?.1
    }
}

enum ThisMac {
    static let isLaptop: Bool = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        if String(decoding: model.prefix { $0 != 0 }, as: UTF8.self).contains("Book") { return true }
        // Apple-silicon models are generic ("Mac15,3"), so fall back to checking for an internal battery.
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
}

extension String {
    /// "Valerys-MacBook-Air.local." → "Valerys MacBook Air"
    var prettyHostName: String {
        var name = self
        if name.hasSuffix(".") { name.removeLast() }
        if let dot = name.firstIndex(of: ".") { name = String(name[..<dot]) }
        return name.replacingOccurrences(of: "-", with: " ")
    }

    /// "Apple, Inc." → "Apple"
    var shortVendor: String {
        let cut = split(whereSeparator: { ",(".contains($0) }).first.map(String.init) ?? self
        let suffixes = [" Inc", " Corporation", " Corp", " Co.", " Ltd", " LLC", " GmbH", " Technologies", " Technology", " Electronics"]
        var result = cut.trimmingCharacters(in: .whitespaces)
        for suffix in suffixes where result.localizedCaseInsensitiveContains(suffix) {
            if let range = result.range(of: suffix, options: [.caseInsensitive, .backwards]) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.isEmpty ? self : result
    }
}
