import FTPServerKit
import Foundation
import Network
import Observation
import SwiftUI
import UIKit

struct ConnectedClient: Identifiable {
    let id: UUID
    let remoteAddress: String
    let connectedAt: Date
    var username: String?
}

/// All control connections from one address; clients such as FileZilla open extra ones for transfers.
struct ClientDevice: Identifiable {
    let remoteAddress: String
    let connections: [ConnectedClient]

    var id: String { remoteAddress }
    var connectedAt: Date { connections.map(\.connectedAt).min() ?? Date() }
    var usernames: [String] { Array(Set(connections.compactMap(\.username))).sorted() }
}

struct TransferItem: Identifiable {
    let info: FTPTransferInfo
    var bytesTransferred: UInt64 = 0
    var bytesPerSecond: Double = 0
    var outcome: FTPTransferOutcome?
    var endDate: Date?
    fileprivate var lastSample = (date: Date(), bytes: UInt64(0))

    var id: UUID { info.id }
    var fileName: String { (info.path as NSString).lastPathComponent }
    var position: UInt64 { info.startOffset + bytesTransferred }
    var fractionCompleted: Double? {
        guard let total = info.expectedSize, total > 0 else { return nil }
        return min(1, Double(position) / Double(total))
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let client: String?
    let message: String
}

@Observable
@MainActor
final class ServerController {
    let settings: ServerSettings
    let rootDirectory = URL.documentsDirectory

    private(set) var state: FTPServerState = .stopped
    private(set) var clients: [ConnectedClient] = []
    private(set) var activeTransfers: [TransferItem] = []
    private(set) var recentTransfers: [TransferItem] = []
    private(set) var log: [LogEntry] = []
    private(set) var addresses: [NetworkInterfaceAddress] = []
    private(set) var fileSystemRevision = 0
    private(set) var activeConfiguration: FTPServerConfiguration?

    @ObservationIgnored private var server: FTPServer?
    /// Identifies the current server so late events from a stopped one are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    private static let maxLogEntries = 500
    private static let maxRecentTransfers = 50

    init(settings: ServerSettings) {
        self.settings = settings
        refreshAddresses()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAddresses() }
        }
        pathMonitor.start(queue: .main)
    }

    var isRunning: Bool { state.isRunning }

    var isBusy: Bool { state == .starting }

    var devices: [ClientDevice] {
        var groups: [String: [ConnectedClient]] = [:]
        var order: [String] = []
        for client in clients {
            if groups[client.remoteAddress] == nil { order.append(client.remoteAddress) }
            groups[client.remoteAddress, default: []].append(client)
        }
        return order.map { ClientDevice(remoteAddress: $0, connections: groups[$0] ?? []) }
    }

    var serverURLs: [(label: String, url: String)] {
        guard case .running(let port) = state else { return [] }
        return addresses.map { address in
            let host = address.isIPv6 ? "[\(address.address)]" : address.address
            return (address.displayName, "ftp://\(host):\(port)")
        }
    }

    func toggle() {
        isRunning || isBusy ? stop() : start()
    }

    func start() {
        guard server == nil, settings.isPortValid else { return }
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let configuration = FTPServerConfiguration(
            port: UInt16(settings.port),
            rootDirectory: rootDirectory,
            username: settings.username.trimmingCharacters(in: .whitespaces),
            password: settings.password,
            allowAnonymous: settings.allowAnonymous,
            readOnly: settings.readOnly,
            bonjourName: settings.bonjourEnabled ? "" : nil,
            welcomeMessage: "FTP Server for iOS ready."
        )
        wantsRunning = true
        activeConfiguration = configuration
        generation += 1
        let generation = generation
        server = FTPServer(configuration: configuration, eventQueue: .main) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.handle(event)
            }
        }
        server?.start()
        updateIdleTimer()
    }

    func stop() {
        wantsRunning = false
        discardServer()
        activeConfiguration = nil
        state = .stopped
        updateIdleTimer()
        endBackgroundTask()
    }

    func refreshAddresses() {
        addresses = NetworkAddresses.localAddresses()
    }

    func clearHistory() {
        log.removeAll()
        recentTransfers.removeAll()
    }

    func noteLocalFileChange() {
        fileSystemRevision += 1
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            guard isRunning else { return }
            appendLog("App moved to background; iOS will pause the server shortly.")
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FTP transfers") { [weak self] in
                self?.endBackgroundTask()
            }
        case .active:
            endBackgroundTask()
            refreshAddresses()
            if wantsRunning, server == nil {
                appendLog("Restarting server")
                start()
            }
        default:
            break
        }
    }

    private func discardServer() {
        server?.stop()
        server = nil
        generation += 1
        clients.removeAll()
        for transfer in activeTransfers {
            finish(transfer.id, bytes: transfer.bytesTransferred, outcome: .aborted)
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = wantsRunning && settings.keepScreenAwake
    }

    private func handle(_ event: FTPServerEvent) {
        switch event {
        case .stateChanged(let newState):
            let wasRunning = state.isRunning
            state = newState
            if case .failed = newState {
                // iOS reclaims the listening socket of suspended apps; restart if it had been working.
                discardServer()
                if wasRunning, wantsRunning, UIApplication.shared.applicationState == .active {
                    appendLog("Restarting server")
                    start()
                }
            }

        case .sessionOpened(let info):
            clients.append(ConnectedClient(id: info.id, remoteAddress: info.remoteAddress, connectedAt: info.connectedAt))

        case .sessionAuthenticated(let sessionID, let username):
            if let index = clients.firstIndex(where: { $0.id == sessionID }) {
                clients[index].username = username
            }

        case .sessionClosed(let sessionID):
            clients.removeAll { $0.id == sessionID }

        case .transferStarted(let info):
            activeTransfers.append(TransferItem(info: info, lastSample: (info.startDate, 0)))

        case .transferProgress(let transferID, let bytes):
            guard let index = activeTransfers.firstIndex(where: { $0.id == transferID }) else { return }
            var item = activeTransfers[index]
            let now = Date()
            let elapsed = now.timeIntervalSince(item.lastSample.date)
            if elapsed > 0 {
                let instantaneous = Double(bytes - min(bytes, item.lastSample.bytes)) / elapsed
                item.bytesPerSecond = item.bytesPerSecond == 0 ? instantaneous : item.bytesPerSecond * 0.7 + instantaneous * 0.3
            }
            item.lastSample = (now, bytes)
            item.bytesTransferred = bytes
            activeTransfers[index] = item

        case .transferEnded(let transferID, let bytes, let outcome):
            finish(transferID, bytes: bytes, outcome: outcome)

        case .fileSystemChanged:
            fileSystemRevision += 1

        case .log(let sessionID, let message):
            let client = sessionID.flatMap { id in clients.first { $0.id == id }?.remoteAddress }
            appendLog(message, client: client)
        }
    }

    private func finish(_ transferID: UUID, bytes: UInt64, outcome: FTPTransferOutcome) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == transferID }) else { return }
        var item = activeTransfers.remove(at: index)
        item.bytesTransferred = bytes
        item.outcome = outcome
        item.endDate = Date()
        let duration = item.endDate!.timeIntervalSince(item.info.startDate)
        item.bytesPerSecond = duration > 0 ? Double(bytes) / duration : 0
        recentTransfers.insert(item, at: 0)
        if recentTransfers.count > Self.maxRecentTransfers { recentTransfers.removeLast() }
    }

    private func appendLog(_ message: String, client: String? = nil) {
        log.append(LogEntry(date: Date(), client: client, message: message))
        if log.count > Self.maxLogEntries { log.removeFirst(log.count - Self.maxLogEntries) }
    }
}
