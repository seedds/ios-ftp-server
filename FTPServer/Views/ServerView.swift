import FTPServerKit
import SwiftUI

struct ServerView: View {
    @Environment(ServerController.self) private var controller

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PowerButton()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                }

                if !controller.activeTransfers.isEmpty {
                    Section("Transfers") {
                        ForEach(controller.activeTransfers) { TransferRow(transfer: $0) }
                    }
                }

                if controller.isRunning {
                    Section("Connect") {
                        if controller.serverURLs.isEmpty {
                            Label("No Wi-Fi connection", systemImage: "wifi.slash")
                                .foregroundStyle(.orange)
                        }
                        ForEach(controller.serverURLs, id: \.url) { AddressRow(label: $0.label, url: $0.url) }
                    }
                    if let configuration = controller.activeConfiguration {
                        LoginSection(configuration: configuration)
                    }
                }

                if !controller.clients.isEmpty {
                    Section("Clients") {
                        ForEach(controller.devices) { ClientRow(device: $0) }
                    }
                }
            }
            .navigationTitle("FTP Server")
        }
    }
}

private struct PowerButton: View {
    @Environment(ServerController.self) private var controller

    var body: some View {
        VStack(spacing: 18) {
            Button {
                controller.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(tint.gradient)
                        .shadow(color: tint.opacity(0.45), radius: controller.isRunning ? 24 : 8)
                    if controller.isBusy {
                        ProgressView().tint(.white).controlSize(.large)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 140, height: 140)
            }
            .buttonStyle(.plain)
            .disabled(!controller.settings.isPortValid)
            .accessibilityLabel(controller.isRunning ? "Stop server" : "Start server")
            .sensoryFeedback(.impact, trigger: controller.isRunning)

            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(.default, value: controller.isRunning)
    }

    private var isFailed: Bool {
        if case .failed = controller.state { return true }
        return !controller.settings.isPortValid
    }

    private var tint: Color {
        switch controller.state {
        case .running: return .green
        case .failed: return .red
        case .starting: return .orange
        case .stopped: return .gray
        }
    }

    private var title: String {
        switch controller.state {
        case .stopped: return "Server is off"
        case .starting: return "Starting…"
        case .running: return "Server is running"
        case .failed: return "Server stopped"
        }
    }

    private var subtitle: String {
        if !controller.settings.isPortValid {
            return "Invalid port. Use \(ServerSettings.portRange.lowerBound)–\(ServerSettings.portRange.upperBound)."
        }
        switch controller.state {
        case .failed(let reason): return reason
        case .running:
            let count = controller.devices.count
            return count == 0 ? "No clients connected" : "\(count) client\(count == 1 ? "" : "s") connected"
        case .starting: return " "
        case .stopped: return "Tap to start"
        }
    }
}

private struct AddressRow: View {
    let label: String
    let url: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(url)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = url
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy address")
        }
        .padding(.vertical, 2)
    }
}

private struct LoginSection: View {
    let configuration: FTPServerConfiguration
    @State private var showPassword = false

    var body: some View {
        Section("Login") {
            if !configuration.username.isEmpty {
                LabeledContent("Username", value: configuration.username)
                LabeledContent("Password") {
                    HStack(spacing: 12) {
                        Text(showPassword ? configuration.password : String(repeating: "•", count: configuration.password.count))
                            .monospaced()
                            .textSelection(.enabled)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                }
            }
            if configuration.allowAnonymous {
                Label("Anonymous login allowed", systemImage: "person.crop.circle.badge.questionmark")
            } else if configuration.username.isEmpty {
                Label("No login enabled", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if configuration.readOnly {
                Label("Read-only", systemImage: "lock")
            }
        }
    }
}

private struct ClientRow: View {
    let device: ClientDevice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.remoteAddress)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(device.connectedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    private var details: String {
        var parts = [device.usernames.isEmpty ? "not logged in" : device.usernames.joined(separator: ", ")]
        if device.connections.count > 1 { parts.append("\(device.connections.count) connections") }
        return parts.joined(separator: " · ")
    }
}

struct TransferRow: View {
    let transfer: TransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(transfer.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.subheadline)
            if transfer.outcome == nil {
                if let fraction = transfer.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
    }

    private var icon: String {
        switch transfer.outcome {
        case .completed: return "checkmark.circle.fill"
        case .aborted: return "xmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case nil: return transfer.info.direction == .upload ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    private var iconColor: Color {
        switch transfer.outcome {
        case .completed: return .green
        case .aborted: return .orange
        case .failed: return .red
        case nil: return .accentColor
        }
    }

    private var trailing: String {
        var parts: [String] = []
        if let total = transfer.info.expectedSize, transfer.outcome == nil {
            parts.append("\(bytes(transfer.position)) / \(bytes(total))")
        } else {
            parts.append(bytes(transfer.position))
        }
        switch transfer.outcome {
        case .failed(let reason): parts.append(reason)
        case .aborted: parts.append("cancelled")
        case .completed, nil:
            if transfer.bytesPerSecond > 0 { parts.append("\(bytes(UInt64(transfer.bytesPerSecond)))/s") }
        }
        return parts.joined(separator: " · ")
    }

    private func bytes(_ count: UInt64) -> String {
        Int64(count).formatted(.byteCount(style: .file))
    }
}
