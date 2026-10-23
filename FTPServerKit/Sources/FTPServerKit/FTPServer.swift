import Foundation
import Network

public final class FTPServer: @unchecked Sendable {
    public let configuration: FTPServerConfiguration

    private let queue = DispatchQueue(label: "FTPServer")
    private let eventQueue: DispatchQueue
    private let eventHandler: @Sendable (FTPServerEvent) -> Void
    private var listener: NWListener?
    private var sessions: [UUID: FTPSession] = [:]

    public init(
        configuration: FTPServerConfiguration,
        eventQueue: DispatchQueue = .main,
        eventHandler: @escaping @Sendable (FTPServerEvent) -> Void
    ) {
        self.configuration = configuration
        self.eventQueue = eventQueue
        self.eventHandler = eventHandler
    }

    public func start() {
        queue.async { self.startListening() }
    }

    public func stop() {
        queue.async { self.stopListening() }
    }

    private func startListening() {
        guard listener == nil else { return }
        do {
            try FileManager.default.createDirectory(at: configuration.rootDirectory, withIntermediateDirectories: true)
        } catch {
            return emit(.stateChanged(.failed("Cannot create the shared folder: \(error.localizedDescription)")))
        }

        let tcp = NWProtocolTCP.Options()
        // Without keepalive, a client that vanished without closing (sleeping laptop, lost Wi-Fi)
        // would stay listed until the idle timeout.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.keepaliveInterval = 15
        tcp.keepaliveCount = 4
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            return emit(.stateChanged(.failed(describe(error))))
        }
        if let name = configuration.bonjourName {
            listener.service = NWListener.Service(name: name.isEmpty ? nil : name, type: "_ftp._tcp")
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            self.listener(listener, didChange: state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        emit(.stateChanged(.starting))
        listener.start(queue: queue)
    }

    private func listener(_ listener: NWListener, didChange state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener.port?.rawValue ?? configuration.port
            emit(.log(sessionID: nil, message: "Listening on port \(port)"))
            emit(.stateChanged(.running(port: port)))
        case .waiting(let error):
            emit(.log(sessionID: nil, message: "Waiting for network: \(describe(error))"))
        case .failed(let error):
            listener.cancel()
            self.listener = nil
            emit(.log(sessionID: nil, message: "Listener failed: \(describe(error))"))
            emit(.stateChanged(.failed(describe(error))))
        default:
            break
        }
    }

    private func stopListening() {
        let wasRunning = listener != nil || !sessions.isEmpty
        listener?.cancel()
        listener = nil
        sessions.values.forEach { $0.shutdown() }
        sessions.removeAll()
        if wasRunning { emit(.log(sessionID: nil, message: "Server stopped")) }
        emit(.stateChanged(.stopped))
    }

    private func accept(_ connection: NWConnection) {
        guard sessions.count < configuration.maxConnections else {
            connection.start(queue: queue)
            connection.send(content: Data("421 Too many connections, try again later.\r\n".utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let session = FTPSession(
            connection: connection,
            configuration: configuration,
            emit: { [weak self] event in self?.emit(event) },
            onClose: { [weak self] id in self?.removeSession(id) }
        )
        sessions[session.id] = session
        session.start()
    }

    private func removeSession(_ id: UUID) {
        queue.async { self.sessions[id] = nil }
    }

    private func emit(_ event: FTPServerEvent) {
        let handler = eventHandler
        eventQueue.async { handler(event) }
    }

    private func describe(_ error: Error) -> String {
        if case NWError.posix(.EADDRINUSE) = error {
            return "Port \(configuration.port) is already in use."
        }
        if case NWError.posix(.EACCES) = error {
            return "Not allowed to listen on port \(configuration.port)."
        }
        return error.localizedDescription
    }
}
