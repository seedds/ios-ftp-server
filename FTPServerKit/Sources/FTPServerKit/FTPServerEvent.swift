import Foundation

public enum FTPServerState: Sendable, Equatable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public enum FTPTransferDirection: Sendable, Equatable {
    /// Client → server (`STOR`, `APPE`, `STOU`).
    case upload
    /// Server → client (`RETR`).
    case download
}

public struct FTPTransferInfo: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let direction: FTPTransferDirection
    public let path: String
    public let startOffset: UInt64
    public let expectedSize: UInt64?
    public let startDate: Date
}

public enum FTPTransferOutcome: Sendable, Equatable {
    case completed
    case aborted
    case failed(String)
}

public struct FTPSessionInfo: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let remoteAddress: String
    public let connectedAt: Date
}

public enum FTPServerEvent: Sendable {
    case stateChanged(FTPServerState)
    case sessionOpened(FTPSessionInfo)
    case sessionAuthenticated(sessionID: UUID, username: String)
    case sessionClosed(sessionID: UUID)
    case transferStarted(FTPTransferInfo)
    /// `bytesTransferred` counts bytes moved by this transfer, excluding `startOffset`.
    case transferProgress(transferID: UUID, bytesTransferred: UInt64)
    case transferEnded(transferID: UUID, bytesTransferred: UInt64, outcome: FTPTransferOutcome)
    case fileSystemChanged(path: String)
    case log(sessionID: UUID?, message: String)
}
