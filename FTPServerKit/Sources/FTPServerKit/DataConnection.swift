import Foundation
import Network

enum DataConnectionError: LocalizedError {
    case timedOut
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "Timed out waiting for data connection"
        case .cancelled: return "Data connection cancelled"
        case .failed(let reason): return reason
        }
    }
}

final class DataConnection: @unchecked Sendable {
    private enum Mode {
        case passive(NWListener)
        case active(NWEndpoint)
    }

    private let queue: DispatchQueue
    private let mode: Mode
    /// Only this peer may connect to a passive port, which stops other hosts from hijacking transfers.
    private let allowedPeer: Data?
    private var connection: NWConnection?
    private var connectionReady = false
    private var earlyFailure: DataConnectionError?
    private var waiter: ((Result<NWConnection, DataConnectionError>) -> Void)?
    private var timeout: DispatchWorkItem?
    private var closed = false

    private init(queue: DispatchQueue, mode: Mode, allowedPeer: Data?) {
        self.queue = queue
        self.mode = mode
        self.allowedPeer = allowedPeer
    }

    static func passive(
        queue: DispatchQueue,
        allowedPeer: NWEndpoint.Host?,
        ready: @escaping @Sendable (Result<(DataConnection, UInt16), DataConnectionError>) -> Void
    ) {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: .any)
        } catch {
            ready(.failure(.failed(error.localizedDescription)))
            return
        }
        let channel = DataConnection(queue: queue, mode: .passive(listener), allowedPeer: allowedPeer?.normalizedAddress)
        // The handler keeps `channel` alive until the listener reports, then removes itself.
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                listener.stateUpdateHandler = nil
                if let port = listener.port?.rawValue {
                    ready(.success((channel, port)))
                } else {
                    channel.close()
                    ready(.failure(.failed("Passive listener has no port")))
                }
            case .failed(let error), .waiting(let error):
                listener.stateUpdateHandler = nil
                channel.close()
                ready(.failure(.failed(error.localizedDescription)))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak channel] incoming in
            channel?.accept(incoming)
        }
        listener.start(queue: queue)
    }

    static func active(queue: DispatchQueue, endpoint: NWEndpoint) -> DataConnection {
        DataConnection(queue: queue, mode: .active(endpoint), allowedPeer: nil)
    }

    func open(timeout seconds: TimeInterval, completion: @escaping (Result<NWConnection, DataConnectionError>) -> Void) {
        guard !closed else { return completion(.failure(.cancelled)) }
        if let earlyFailure { return completion(.failure(earlyFailure)) }
        if let connection, connectionReady {
            return completion(.success(connection))
        }
        waiter = completion
        let item = DispatchWorkItem { [weak self] in self?.deliver(.failure(.timedOut)) }
        timeout = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)

        if case .active(let endpoint) = mode, connection == nil {
            let outgoing = NWConnection(to: endpoint, using: .tcp)
            connection = outgoing
            monitor(outgoing)
            outgoing.start(queue: queue)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if case .passive(let listener) = mode {
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        deliver(.failure(.cancelled))
        connection?.cancel()
        connection = nil
    }

    private func accept(_ incoming: NWConnection) {
        let peer = incoming.endpoint.host?.normalizedAddress
        guard connection == nil, !closed, allowedPeer == nil || peer == allowedPeer else {
            incoming.cancel()
            return
        }
        if case .passive(let listener) = mode { listener.cancel() }
        connection = incoming
        monitor(incoming)
        incoming.start(queue: queue)
    }

    private func monitor(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connectionReady = true
                self.deliver(.success(connection))
            case .failed(let error), .waiting(let error):
                connection.cancel()
                self.connectionReady = false
                self.earlyFailure = .failed(error.localizedDescription)
                self.deliver(.failure(.failed(error.localizedDescription)))
            default:
                break
            }
        }
    }

    private func deliver(_ result: Result<NWConnection, DataConnectionError>) {
        guard let waiter else { return }
        self.waiter = nil
        timeout?.cancel()
        timeout = nil
        waiter(result)
    }
}
