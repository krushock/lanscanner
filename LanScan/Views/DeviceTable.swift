import SwiftUI

struct DeviceTable: View {
    @Environment(ScanModel.self) private var model
    let devices: [Device]
    @Binding var sortOrder: [KeyPathComparator<Device>]
    @State private var renaming: Device?

    var body: some View {
        @Bindable var model = model

        Table(devices, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("") { device in
                StatusDot(isOnline: device.isOnline)
            }
            .width(14)

            TableColumn("Name", value: \.displayName) { device in
                DeviceNameCell(device: device)
            }
            .width(min: 180, ideal: 240)

            TableColumn("IP Address", value: \.ip) { device in
                Text(device.ip.description)
                    .monospacedDigit()
            }
            .width(min: 100, ideal: 115)

            TableColumn("IPv6", value: \.ipv6SortKey) { device in
                Text(device.ipv6?.first?.description ?? "—")
                    .font(.body.monospaced())
                    .foregroundStyle(device.ipv6 == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help((device.ipv6 ?? []).map(\.description).joined(separator: "\n"))
            }
            .width(min: 120, ideal: 200)

            TableColumn("MAC Address", value: \.macSortKey) { device in
                Text(device.mac?.description ?? "—")
                    .font(.body.monospaced())
                    .foregroundStyle(device.mac == nil ? .tertiary : .primary)
            }
            .width(min: 130, ideal: 150)

            TableColumn("Vendor", value: \.vendorDescription) { device in
                Text(device.vendorDescription)
                    .foregroundStyle(device.vendor == nil ? .secondary : .primary)
            }
            .width(min: 100, ideal: 180)

            TableColumn("Hostname", value: \.hostnameSortKey) { device in
                Text(device.hostname ?? "—")
                    .foregroundStyle(device.hostname == nil ? .tertiary : .secondary)
            }
            .width(min: 100, ideal: 190)

            TableColumn("Ping", value: \.latencySortKey) { device in
                if let latency = device.latency {
                    Text(latency < 1 ? "<1 ms" : "\(Int(latency.rounded())) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 50, ideal: 60)

            TableColumn("Last Seen", value: \.lastSeen) { device in
                Group {
                    if device.isOnline {
                        Text("Now")
                    } else {
                        Text(device.lastSeen, format: .relative(presentation: .named))
                    }
                }
                .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Device.ID.self) { ids in
            DeviceContextMenu(ids: ids, renaming: $renaming)
        } primaryAction: { ids in
            if let id = ids.first, let device = model.devices[id] { open(device, scheme: "http") }
        }
        .sheet(item: $renaming) { device in
            RenameSheet(device: device)
        }
    }

    private func open(_ device: Device, scheme: String) {
        if let url = URL(string: "\(scheme)://\(device.ip)") { NSWorkspace.shared.open(url) }
    }
}

struct StatusDot: View {
    let isOnline: Bool

    var body: some View {
        Circle()
            .fill(isOnline ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 8, height: 8)
            .shadow(color: isOnline ? .green.opacity(0.6) : .clear, radius: 3)
            .accessibilityLabel(isOnline ? "Online" : "Offline")
    }
}

struct DeviceIcon: View {
    let kind: DeviceKind
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind.color.gradient, in: .rect(cornerRadius: size * 0.28))
    }
}

private struct DeviceNameCell: View {
    let device: Device

    var body: some View {
        HStack(spacing: 10) {
            DeviceIcon(kind: device.kind)
                .saturation(device.isOnline ? 1 : 0)
                .opacity(device.isOnline ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(device.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if device.isThisDevice { Tag("This Mac") }
                    if device.isGateway { Tag("Router") }
                }
                Text(device.modelDescription ?? device.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(device.isOnline ? .primary : .secondary)
        .padding(.vertical, 2)
    }
}

struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.15), in: .capsule)
    }
}

struct DeviceContextMenu: View {
    @Environment(ScanModel.self) private var model
    let ids: Set<Device.ID>
    @Binding var renaming: Device?

    var body: some View {
        let devices = ids.compactMap { model.devices[$0] }
        if let device = devices.first, devices.count == 1 {
            Button("Open in Browser", systemImage: "safari") { open(device, "http") }
            Button("Connect via SSH", systemImage: "terminal") { open(device, "ssh") }
            Button("Connect to File Share", systemImage: "folder") { open(device, "smb") }
            Divider()
            Button("Rename…", systemImage: "pencil") { renaming = device }
            if device.mac != nil, !device.isThisDevice {
                Button("Wake on LAN", systemImage: "power") { _ = model.wake(device) }
            }
            Divider()
            Button("Copy IP Address", systemImage: "doc.on.doc") { copy(device.ip.description) }
            if let mac = device.mac { Button("Copy MAC Address") { copy(mac.description) } }
            if let host = device.hostname { Button("Copy Hostname") { copy(host) } }
            Divider()
        }
        if !devices.isEmpty {
            Button(devices.count == 1 ? "Forget Device" : "Forget \(devices.count) Devices", systemImage: "trash", role: .destructive) {
                model.forget(ids)
            }
        }
    }

    private func open(_ device: Device, _ scheme: String) {
        if let url = URL(string: "\(scheme)://\(device.ip)") { NSWorkspace.shared.open(url) }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

struct RenameSheet: View {
    @Environment(ScanModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: Device
    @State private var name = ""

    var body: some View {
        VStack(spacing: 16) {
            DeviceIcon(kind: device.kind, size: 48)
            Text("Rename Device").font(.headline)
            TextField(device.displayName, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .onAppear { name = device.customName ?? "" }
    }

    private func save() {
        model.rename(device.id, to: name)
        dismiss()
    }
}
