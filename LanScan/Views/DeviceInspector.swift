import SwiftUI

struct DeviceInspector: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        let selected = model.selection.compactMap { model.devices[$0] }
        Group {
            if selected.count == 1, let device = selected.first {
                DeviceDetail(device: device)
            } else if selected.count > 1 {
                ContentUnavailableView("\(selected.count) Devices Selected", systemImage: "square.stack.3d.up")
            } else {
                NetworkOverview()
            }
        }
    }
}

private struct DeviceDetail: View {
    @Environment(ScanModel.self) private var model
    let device: Device
    @State private var name = ""
    @State private var wakeSent = false
    @Namespace private var glass

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                actions
                section("Network") {
                    row("IP Address", device.ip.description, mono: true)
                    ForEach(Array((device.ipv6 ?? []).enumerated()), id: \.offset) { index, address in
                        row(index == 0 ? "IPv6" : "", address.description, mono: true)
                    }
                    row("MAC Address", device.mac?.description, mono: true)
                    row("Vendor", device.vendorDescription)
                    if let latency = device.latency { row("Response Time", String(format: "%.1f ms", latency)) }
                }
                section("Names") {
                    row("DHCP", device.identity.dhcpName)
                    row("Bonjour", device.identity.mdnsName)
                    row("DNS", device.identity.dnsName)
                    row("NetBIOS", device.identity.netbiosName)
                    row("UPnP", device.identity.upnpName)
                }
                section("Device") {
                    row("Type", device.kind.title)
                    if let product = device.modelDescription {
                        let reported = device.identity.model ?? device.identity.upnpModel
                        row("Model", reported == nil || reported == product ? product : "\(product) (\(reported!))")
                    }
                    row("First Seen", device.firstSeen.formatted(date: .abbreviated, time: .shortened))
                    row("Last Seen", device.isOnline ? "Now" : device.lastSeen.formatted(date: .abbreviated, time: .shortened))
                }
                if !device.identity.services.isEmpty {
                    servicesSection
                }
            }
            .padding(16)
        }
        .onChange(of: device.id, initial: true) { name = device.customName ?? "" }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(device.kind.color)
                .frame(width: 84, height: 84)
                .glassEffect(.regular.tint(device.kind.color.opacity(0.22)), in: .circle)

            TextField("Name", text: $name, prompt: Text(device.displayName))
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .onSubmit { model.rename(device.id, to: name) }

            HStack(spacing: 6) {
                StatusDot(isOnline: device.isOnline)
                Text(device.isOnline ? "Online" : "Offline")
                if device.isThisDevice { Text("· This Mac") }
                if device.isGateway { Text("· Router") }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                action("Web", "safari") { open("http") }
                action("Files", "folder") { open("smb") }
                action("SSH", "terminal") { open("ssh") }
                if device.mac != nil, !device.isThisDevice {
                    action(wakeSent ? "Sent" : "Wake", wakeSent ? "checkmark" : "power") {
                        wakeSent = model.wake(device)
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            wakeSent = false
                        }
                    }
                }
            }
        }
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.caption)
            }
            .frame(width: 52, height: 44)
        }
        .buttonStyle(.glass)
        .glassEffectID(title, in: glass)
    }

    private var servicesSection: some View {
        section("Services") {
            ForEach(device.identity.services, id: \.self) { service in
                HStack {
                    Label(ServiceNames.name(for: service), systemImage: ServiceNames.symbol(for: service))
                    Spacer()
                    Text(service)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? "—")
                .font(mono ? .body.monospaced() : .body)
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func open(_ scheme: String) {
        if let url = URL(string: "\(scheme)://\(device.ip)") { NSWorkspace.shared.open(url) }
    }
}

/// Shown when nothing is selected: a breakdown of the network by device type.
private struct NetworkOverview: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        let devices = model.networkDevices
        if devices.isEmpty {
            ContentUnavailableView("No Selection", systemImage: "cursorarrow.click",
                                   description: Text("Select a device to see its details."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        stat("\(model.count(for: .online))", "Online", .green)
                        stat("\(devices.count)", "Known", .accentColor)
                    }
                    Text("By Type")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 10) {
                        ForEach(DeviceCategory.allCases) { category in
                            let count = devices.count { $0.kind.category == category && $0.isOnline }
                            if count > 0 {
                                Button {
                                    model.filter = .category(category)
                                } label: {
                                    HStack {
                                        Label(category.title, systemImage: category.symbol)
                                        Spacer()
                                        Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(12)
                    .background(.background.secondary, in: .rect(cornerRadius: 14))
                    Text("Select a device to see its details.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .padding(16)
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassEffect(.regular.tint(tint.opacity(0.15)), in: .rect(cornerRadius: 18))
    }
}

enum ServiceNames {
    private static let table: [String: (String, String)] = [
        "_airplay._tcp": ("AirPlay", "airplayvideo"),
        "_raop._tcp": ("AirPlay Audio", "airplayaudio"),
        "_companion-link._tcp": ("Apple Continuity", "link"),
        "_googlecast._tcp": ("Google Cast", "tv.badge.wifi"),
        "_hap._tcp": ("HomeKit", "homekit"),
        "_homekit._tcp": ("HomeKit", "homekit"),
        "_ipp._tcp": ("Printing (IPP)", "printer"),
        "_ipps._tcp": ("Secure Printing", "printer"),
        "_printer._tcp": ("Printing (LPD)", "printer"),
        "_pdl-datastream._tcp": ("Raw Printing", "printer"),
        "_uscan._tcp": ("Scanner", "scanner"),
        "_smb._tcp": ("File Sharing (SMB)", "folder"),
        "_afpovertcp._tcp": ("File Sharing (AFP)", "folder"),
        "_adisk._tcp": ("Time Machine", "clock.arrow.circlepath"),
        "_ssh._tcp": ("Remote Login (SSH)", "terminal"),
        "_sftp-ssh._tcp": ("SFTP", "terminal"),
        "_rfb._tcp": ("Screen Sharing", "rectangle.on.rectangle"),
        "_http._tcp": ("Web Server", "globe"),
        "_https._tcp": ("Secure Web Server", "lock.shield"),
        "_spotify-connect._tcp": ("Spotify Connect", "music.note"),
        "_sonos._tcp": ("Sonos", "hifispeaker"),
        "_sleep-proxy._udp": ("Sleep Proxy", "moon.zzz"),
        "_matter._tcp": ("Matter", "point.3.connected.trianglepath.dotted"),
        "_matterc._udp": ("Matter Commissioning", "point.3.connected.trianglepath.dotted"),
        "_meshcop._udp": ("Thread Border Router", "point.3.filled.connected.trianglepath.dotted"),
        "_trel._udp": ("Thread", "point.3.filled.connected.trianglepath.dotted"),
        "_srpl-tls._tcp": ("Thread", "point.3.filled.connected.trianglepath.dotted"),
        "_remotepairing._tcp": ("Remote Pairing", "iphone.radiowaves.left.and.right"),
        "_apple-mobdev2._tcp": ("Wi-Fi Sync", "arrow.triangle.2.circlepath"),
        "_device-info._tcp": ("Device Info", "info.circle"),
        "_workstation._tcp": ("Workstation", "desktopcomputer"),
        "_daap._tcp": ("Music Sharing", "music.note.list"),
    ]

    static func name(for service: String) -> String {
        if let entry = table[service] { return entry.0 }
        let core = service.split(separator: ".").first.map { $0.dropFirst() } ?? Substring(service)
        return core.replacingOccurrences(of: "-", with: " ").capitalized
    }

    static func symbol(for service: String) -> String { table[service]?.1 ?? "app.connected.to.app.below.fill" }
}
