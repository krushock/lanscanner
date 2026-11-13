import Foundation

/// Product recognition rules loaded from `DeviceCatalog.json`, so new devices can be taught
/// to the app by editing data rather than code. See the file's `about` key for the rule format.
final class DeviceCatalog: Sendable {
    static let shared = DeviceCatalog(url: Bundle.main.url(forResource: "DeviceCatalog", withExtension: "json"))

    struct Match: Sendable {
        let product: String?
        let kind: DeviceKind?
    }

    private struct File: Decodable {
        let apple: [String: String]
        let rules: [RawRule]
    }

    private struct RawRule: Decodable {
        struct Conditions: Decodable {
            let vendor: String?
            let services: [String]?
            let model: String?
            let upnpModel: String?
            let upnp: String?
            let name: String?
        }

        let product: String?
        let kind: DeviceKind?
        let match: Conditions
    }

    private struct Rule: @unchecked Sendable {
        let product: String?
        let kind: DeviceKind?
        let vendor: String?
        let services: Set<String>?
        let model: NSRegularExpression?
        let upnpModel: NSRegularExpression?
        let upnp: NSRegularExpression?
        let name: NSRegularExpression?
    }

    private let apple: [String: String]
    private let rules: [Rule]

    init(url: URL?) {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            apple = [:]
            rules = []
            return
        }
        func regex(_ pattern: String?) -> NSRegularExpression? {
            pattern.flatMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        }
        apple = file.apple
        rules = file.rules.map { raw in
            Rule(product: raw.product, kind: raw.kind, vendor: raw.match.vendor?.lowercased(),
                 services: raw.match.services.map(Set.init), model: regex(raw.match.model),
                 upnpModel: regex(raw.match.upnpModel), upnp: regex(raw.match.upnp), name: regex(raw.match.name))
        }
    }

    var ruleCount: Int { rules.count }

    /// The marketing name for an Apple model identifier such as "Mac14,2".
    func appleProduct(_ identifier: String) -> String? { apple[identifier] }

    func match(_ device: Device) -> Match? {
        let identity = device.identity
        let vendor = device.vendor?.lowercased() ?? ""
        let services = Set(identity.services)
        let names = [identity.dhcpName, identity.mdnsName, identity.dnsName, identity.netbiosName, identity.friendlyName]
            .compactMap { $0?.strippingLocalDomain }

        for rule in rules {
            if let wanted = rule.vendor, !vendor.contains(wanted) { continue }
            if let wanted = rule.services, wanted.isDisjoint(with: services) { continue }
            if let pattern = rule.model, !pattern.matches(identity.model) { continue }
            if let pattern = rule.upnpModel, !pattern.matches(identity.upnpModel) { continue }
            if let pattern = rule.upnp, !pattern.matches(identity.upnpName) { continue }
            if let pattern = rule.name, !names.contains(where: { pattern.matches($0) }) { continue }
            return Match(product: rule.product, kind: rule.kind)
        }
        return nil
    }
}

private extension NSRegularExpression {
    func matches(_ string: String?) -> Bool {
        guard let string else { return false }
        return firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}

enum ModelNames {
    /// Exact Apple names from the catalog, else the family: "MacBookPro99,1" → "MacBook Pro".
    static func friendly(_ identifier: String) -> String {
        if let product = DeviceCatalog.shared.appleProduct(identifier) { return product }
        let families: [(String, String)] = [
            ("MacBookAir", "MacBook Air"), ("MacBookPro", "MacBook Pro"), ("MacBook", "MacBook"),
            ("Macmini", "Mac mini"), ("MacPro", "Mac Pro"), ("iMac", "iMac"), ("Mac", "Mac"),
            ("iPhone", "iPhone"), ("iPad", "iPad"), ("Watch", "Apple Watch"),
            ("AppleTV", "Apple TV"), ("AudioAccessory", "HomePod"),
        ]
        guard identifier.contains(",") else { return identifier }
        return families.first { identifier.hasPrefix($0.0) }?.1 ?? identifier
    }
}

extension String {
    var strippingLocalDomain: String {
        var name = self
        if name.hasSuffix(".") { name.removeLast() }
        if name.lowercased().hasSuffix(".local") { name.removeLast(6) }
        return name
    }

    /// Serial numbers, UUIDs and "android-1a2b…" style names that say nothing to a person.
    var looksMachineGenerated: Bool {
        let name = strippingLocalDomain
        // Samsung devices use their bare model code ("SM-L500") as the host name.
        if name.range(of: "^(android[-_]|SM-[A-Z]\\d{3}[A-Z0-9]*$)", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let compact = name.filter { $0.isLetter || $0.isNumber }
        if compact.range(of: "[0-9]{6,}", options: .regularExpression) != nil { return true }
        return compact.range(of: "[0-9a-f]{12,}", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
