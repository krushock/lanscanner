import SwiftUI

/// Toolbar menu for picking which network (interface + IPv4 address) to scan.
struct NetworkMenu: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Menu {
            Picker("Network", selection: $model.selectedInterfaceID) {
                ForEach(model.interfaces) { interface in
                    Label(interface.label, systemImage: interface.symbol)
                        .tag(Optional(interface.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Refresh Networks", systemImage: "arrow.clockwise") { model.refreshInterfaces() }
        } label: {
            Label(model.selectedInterface?.displayName ?? "No Network",
                  systemImage: model.selectedInterface?.symbol ?? "network.slash")
                .labelStyle(.titleAndIcon)
        }
        .disabled(model.isScanning)
        .help("Choose the network to scan")
    }
}

/// Toolbar menu for automatic rescans.
struct RescanMenu: View {
    @Environment(ScanModel.self) private var model
    @State private var editingCustom = false

    private static let intervals: [(String, Double)] = [
        ("Off", 0), ("Every 15 Seconds", 15), ("Every 30 Seconds", 30), ("Every Minute", 60),
        ("Every 5 Minutes", 300), ("Every 15 Minutes", 900), ("Every 30 Minutes", 1800), ("Every Hour", 3600),
    ]

    private var isCustom: Bool { !Self.intervals.contains { $0.1 == model.rescanInterval } }

    var body: some View {
        @Bindable var model = model

        Menu {
            Picker("Rescan Automatically", selection: $model.rescanInterval) {
                ForEach(Self.intervals, id: \.1) { title, seconds in
                    Text(title).tag(seconds)
                }
                if isCustom {
                    Text("Every \(Self.format(model.rescanInterval))").tag(model.rescanInterval)
                }
            }
            .pickerStyle(.inline)
            Button("Custom…") { editingCustom = true }
            if let next = model.nextRescan {
                Divider()
                Text("Next scan \(next, format: .relative(presentation: .named))")
            }
        } label: {
            if model.rescanInterval > 0 {
                Label(shortTitle, systemImage: "timer")
                    .labelStyle(.titleAndIcon)
            } else {
                Label("Auto-Rescan", systemImage: "timer")
            }
        }
        .help("Rescan the network automatically")
        .sheet(isPresented: $editingCustom) {
            CustomIntervalSheet(initial: model.rescanInterval) { model.rescanInterval = $0 }
        }
    }

    private var shortTitle: String { Self.format(model.rescanInterval) }

    /// 15 → "15 s", 300 → "5 min", 7200 → "2 h", 90 → "90 s".
    static func format(_ seconds: Double) -> String {
        let value = Int(seconds)
        if value >= 3600, value % 3600 == 0 { return "\(value / 3600) h" }
        if value >= 60, value % 60 == 0 { return "\(value / 60) min" }
        return "\(value) s"
    }
}

private struct CustomIntervalSheet: View {
    enum Unit: Double, CaseIterable, Identifiable {
        case seconds = 1, minutes = 60, hours = 3600
        var id: Self { self }
        var title: String {
            switch self {
            case .seconds: "Seconds"
            case .minutes: "Minutes"
            case .hours: "Hours"
            }
        }
    }

    static let minimum: Double = 10

    let initial: Double
    let apply: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amount = 10
    @State private var unit = Unit.minutes

    private var seconds: Double { Double(amount) * unit.rawValue }
    private var isValid: Bool { amount > 0 && seconds >= Self.minimum && seconds <= 24 * 3600 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Rescan Interval").font(.headline)
            HStack {
                Text("Every")
                TextField("Amount", value: $amount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .monospacedDigit()
                Stepper("Amount", value: $amount, in: 1...999).labelsHidden()
                Picker("Unit", selection: $unit) {
                    ForEach(Unit.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if !isValid {
                Label("Choose between 10 seconds and 24 hours.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set") {
                    apply(seconds)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            // Start from the current interval in its largest whole unit.
            let current = initial > 0 ? initial : 600
            unit = Unit.allCases.last { current >= $0.rawValue && current.truncatingRemainder(dividingBy: $0.rawValue) == 0 } ?? .seconds
            amount = Int(current / unit.rawValue)
        }
    }
}

/// Toolbar button that opens the scan options: network, address range and IPv6.
struct ScanOptionsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Scan Options", systemImage: "slider.horizontal.3")
        }
        .help("Network, address range and IPv6")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScanOptionsView()
        }
    }
}

struct ScanOptionsView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Network") {
                Picker("Interface", selection: $model.selectedInterfaceID) {
                    ForEach(model.interfaces) { interface in
                        Text(interface.label).tag(Optional(interface.id))
                    }
                }
                .disabled(model.isScanning)
            }

            Section {
                Picker("Range", selection: $model.rangeMode) {
                    Text("Whole Subnet").tag(RangeMode.automatic)
                    Text("Custom").tag(RangeMode.custom)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.rangeMode) { _, mode in
                    if mode == .custom, model.customRangeStart.isEmpty { model.resetCustomRange() }
                }

                if model.rangeMode == .custom {
                    TextField("From", text: $model.customRangeStart, prompt: Text("192.168.1.1"))
                        .monospacedDigit()
                    TextField("To", text: $model.customRangeEnd, prompt: Text("192.168.1.254"))
                        .monospacedDigit()
                }
            } header: {
                Text("Address Range")
            } footer: {
                rangeFooter
            }

            Section {
                Toggle("Discover IPv6 addresses", isOn: $model.includeIPv6)
            } footer: {
                Text("Finds each device's IPv6 addresses through the all-nodes multicast group and the neighbor cache.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var rangeFooter: some View {
        switch model.scanRange {
        case .success(let range):
            HStack {
                Text(verbatim: "\(range.lowerBound) – \(range.upperBound) · \((Int(range.upperBound.raw - range.lowerBound.raw) + 1).formatted()) addresses")
                    .monospacedDigit()
                Spacer()
                if model.rangeMode == .custom {
                    Button("Use Subnet") { model.resetCustomRange() }
                        .buttonStyle(.link)
                }
            }
            .foregroundStyle(.secondary)
        case .failure(let error):
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case nil:
            Text("No active network.").foregroundStyle(.secondary)
        }
    }
}
