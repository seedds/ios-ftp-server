import SwiftUI

struct ActivityView: View {
    @Environment(ServerController.self) private var controller

    var body: some View {
        NavigationStack {
            List {
                if !controller.recentTransfers.isEmpty {
                    Section("Transfers") {
                        ForEach(controller.recentTransfers) { TransferRow(transfer: $0) }
                    }
                }
                if !controller.log.isEmpty {
                    Section("Log") {
                        ForEach(controller.log.reversed()) { LogRow(entry: $0) }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 32)
            .overlay {
                if controller.log.isEmpty && controller.recentTransfers.isEmpty {
                    ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle")
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Clear", role: .destructive) { controller.clearHistory() }
                    .disabled(controller.log.isEmpty && controller.recentTransfers.isEmpty)
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                .foregroundStyle(.secondary)
            Text(entry.message)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let client = entry.client {
                Text(client)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospaced())
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}
