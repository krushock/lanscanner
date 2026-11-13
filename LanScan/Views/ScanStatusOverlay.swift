import SwiftUI

/// A floating Liquid Glass capsule that shows scan progress and morphs into a summary when done.
struct ScanStatusOverlay: View {
    @Environment(ScanModel.self) private var model
    @Namespace private var namespace
    @State private var showSummary = false

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                if model.isScanning {
                    scanningPill
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("pill", in: namespace)

                    Button {
                        model.stopScan()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("stop", in: namespace)
                    .help("Stop scanning")
                } else if showSummary, let summary = model.lastSummary {
                    summaryPill(summary)
                        .glassEffect(.regular.tint(.green.opacity(0.15)), in: .capsule)
                        .glassEffectID("pill", in: namespace)
                }
            }
        }
        .padding(.bottom, 18)
        .animation(.spring(duration: 0.45, bounce: 0.25), value: model.isScanning)
        .animation(.spring(duration: 0.45, bounce: 0.25), value: showSummary)
        .onChange(of: model.lastSummary) { _, summary in
            guard summary != nil else { return }
            showSummary = true
            Task {
                try? await Task.sleep(for: .seconds(4))
                showSummary = false
            }
        }
    }

    private var scanningPill: some View {
        HStack(spacing: 12) {
            ProgressView(value: model.progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.phase == .resolving ? "Identifying devices…" : "Discovering devices…")
                    .font(.callout.weight(.medium))
                Text("\(model.selectedInterface?.cidr ?? "") · \(model.count(for: .online)) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .padding(.vertical, 9)
        .animation(.default, value: model.count(for: .online))
    }

    private func summaryPill(_ summary: ScanModel.ScanSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Found \(summary.found) device\(summary.found == 1 ? "" : "s")")
                .font(.callout.weight(.medium))
            if summary.new > 0 {
                Text("\(summary.new) new")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.2), in: .capsule)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}
