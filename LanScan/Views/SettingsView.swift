import SwiftUI

struct SettingsView: View {
    @Environment(ScanModel.self) private var model
    @AppStorage("scanOnLaunch") private var scanOnLaunch = true
    @State private var confirmForget = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Scanning") {
                Toggle("Scan when LanScan opens", isOn: $scanOnLaunch)
                Toggle("Show offline devices", isOn: $model.showOffline)
            }

            Section {
                LabeledContent("Vendor database") {
                    switch model.vendorStatus {
                    case .loading:
                        ProgressView().controlSize(.small)
                    case .ready:
                        VStack(alignment: .trailing) {
                            Text("\(VendorDatabase.shared.count.formatted()) manufacturers")
                            if let date = VendorDatabase.shared.lastUpdated {
                                Text("Updated \(date.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                    }
                }
                Button("Update Now") {
                    Task { await model.loadVendors(force: true) }
                }
                .disabled(model.vendorStatus == .loading)
            } header: {
                Text("Manufacturers")
            } footer: {
                Text("Vendor names come from the Wireshark OUI list and refresh monthly.")
            }

            Section("Privacy") {
                Button("Open Local Network Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
                Button("Forget All Devices…", role: .destructive) { confirmForget = true }
                    .confirmationDialog("Forget all remembered devices?", isPresented: $confirmForget) {
                        Button("Forget All", role: .destructive) { model.forgetAll() }
                    } message: {
                        Text("Custom names and history for every network will be removed.")
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
