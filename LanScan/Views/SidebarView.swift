import SwiftUI

struct SidebarView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        let selection = Binding<SidebarFilter?>(
            get: { model.filter },
            set: { if let filter = $0 { model.filter = filter } }
        )

        List(selection: selection) {
            Section("Devices") {
                row(.all, "All Devices", "square.grid.2x2")
                row(.online, "Online", "circle.fill", tint: .green)
                if model.showOffline, model.count(for: .offline) > 0 {
                    row(.offline, "Offline", "circle.dashed", tint: .secondary)
                }
            }

            let categories = DeviceCategory.allCases.filter { model.count(for: .category($0)) > 0 }
            if !categories.isEmpty {
                Section("Types") {
                    ForEach(categories) { category in
                        row(.category(category), category.title, category.symbol)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NetworkCard()
                .padding(10)
        }
    }

    private func row(_ filter: SidebarFilter, _ title: String, _ symbol: String, tint: Color? = nil) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
                .imageScale(filter == .online || filter == .offline ? .small : .medium)
        }
        .badge(model.count(for: filter))
        .tag(filter)
    }
}

/// The current interface and its addressing, pinned to the bottom of the sidebar.
private struct NetworkCard: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 10) {
            if let interface = model.selectedInterface {
                HStack(spacing: 10) {
                    Image(systemName: interface.symbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 34, height: 34)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .circle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(interface.displayName).font(.headline)
                        Text(interface.bsdName).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    info("IP Address", interface.address.description)
                    info("Subnet", interface.cidr)
                    if let router = interface.router { info("Router", router.description) }
                    if let ipv6 = interface.ipv6Addresses.first(where: { !$0.isLinkLocal }) {
                        info("IPv6", ipv6.description)
                    }
                    if let date = model.lastScanDate {
                        GridRow {
                            Text("Scanned").foregroundStyle(.secondary)
                            Text(date, format: .relative(presentation: .named))
                        }
                    }
                }
                .font(.caption)
            } else {
                Label("No active network", systemImage: "network.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}
