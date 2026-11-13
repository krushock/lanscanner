import SwiftUI

@main
struct LanScanApp: App {
    @State private var model = ScanModel()
    @AppStorage("scanOnLaunch") private var scanOnLaunch = true

    var body: some Scene {
        Window("LanScan", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 480)
                .task {
                    if scanOnLaunch { model.startScan() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if !model.isScanning { model.refreshInterfaces() }
                }
        }
        .defaultSize(width: 1180, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button(model.isScanning ? "Stop Scan" : "Scan Network") { model.toggleScan() }
                    .keyboardShortcut("r")
                Button("Stop") { model.stopScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
                Button("Clear Device List") { model.clearDevices() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Divider()
                Toggle("Show Offline Devices", isOn: $model.showOffline)
                Toggle("Discover IPv6 Addresses", isOn: $model.includeIPv6)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Export as CSV…") {
                    model.exportCSV(model.visibleDevices(sortedBy: [KeyPathComparator(\.ip)]))
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

