import SwiftUI

struct ContentView: View {
    @Environment(ScanModel.self) private var model
    @State private var showInspector = true
    @State private var sortOrder = [KeyPathComparator(\Device.ip)]

    var body: some View {
        @Bindable var model = model
        let devices = model.visibleDevices(sortedBy: sortOrder)

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            DeviceTable(devices: devices, sortOrder: $sortOrder)
                .overlay {
                    if devices.isEmpty { EmptyStateView(isFiltered: !model.networkDevices.isEmpty) }
                }
                .overlay(alignment: .top) {
                    if model.needsLocalNetworkAccess { LocalNetworkBanner() }
                }
                .overlay(alignment: .bottom) { ScanStatusOverlay() }
                .inspector(isPresented: $showInspector) {
                    DeviceInspector()
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .navigationTitle(model.selectedInterface?.displayName ?? "LanScan")
        .navigationSubtitle(subtitle(devices))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Name, IP, MAC or vendor")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                NetworkMenu()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.clearDevices()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.networkDevices.isEmpty)
                .help("Clear the device list for this network (custom names are kept)")

                RescanMenu()
                ScanOptionsButton()
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleScan()
                } label: {
                    Label(model.isScanning ? "Stop" : "Scan",
                          systemImage: model.isScanning ? "stop.fill" : "dot.radiowaves.left.and.right")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .tint(model.isScanning ? .red : .accentColor)
                .disabled(!model.isScanning && !model.canScan)
                .help(model.isScanning ? "Stop scanning (⌘.)" : "Scan the network (⌘R)")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide device details")
            }
        }
    }

    private func subtitle(_ devices: [Device]) -> String {
        guard let interface = model.selectedInterface else { return "No active network" }
        let online = model.count(for: .online)
        var range = interface.cidr
        if model.rangeMode == .custom, case .success(let custom) = model.scanRange {
            range = "\(custom.lowerBound) – \(custom.upperBound)"
        }
        return "\(range) · \(online) online"
    }
}

struct EmptyStateView: View {
    @Environment(ScanModel.self) private var model
    let isFiltered: Bool

    var body: some View {
        if model.selectedInterface == nil {
            ContentUnavailableView(
                "Not Connected",
                systemImage: "network.slash",
                description: Text("Connect to Wi-Fi or Ethernet to discover devices on your network.")
            )
        } else if isFiltered {
            ContentUnavailableView.search(text: model.searchText)
        } else if !model.isScanning {
            ContentUnavailableView {
                Label("No Devices Yet", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("Scan your network to see every device that's connected to it.")
            } actions: {
                Button("Scan Network") { model.startScan() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
    }
}

struct LocalNetworkBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Network access is off")
                    .font(.headline)
                Text("Without it macOS hides MAC addresses, so vendors and offline devices can't be tracked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 20))
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }
}
