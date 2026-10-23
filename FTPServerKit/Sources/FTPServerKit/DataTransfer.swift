import Foundation
import Network

final class DataTransfer: @unchecked Sendable {
    enum Source {
        case file(FileHandle)
        case data(Data)
    }

    enum Direction {
        case send(Source)
        case receive(FileHandle)
    }

    enum Failure: Error {
        case aborted
        case io(String)
    }

    private static let chunkSize = 256 * 1024
    private static let progressInterval: TimeInterval = 0.25

    private let connection: NWConnection
    private let direction: Direction
    private let progress: (UInt64) -> Void
    private var completion: ((UInt64, Failure?) -> Void)?
    private var bytesTransferred: UInt64 = 0
    private var dataOffset = 0
    private var lastProgress = Date.distantPast

    init(
        connection: NWConnection,
        direction: Direction,
        progress: @escaping (UInt64) -> Void,
        completion: @escaping (_ bytesTransferred: UInt64, _ failure: Failure?) -> Void
    ) {
        self.connection = connection
        self.direction = direction
        self.progress = progress
        self.completion = completion
    }

    func start() {
        switch direction {
        case .send: sendNextChunk()
        case .receive(let handle): receiveNextChunk(into: handle)
        }
    }

    func cancel() {
        connection.forceCancel()
        finish(failure: .aborted)
    }

    private func sendNextChunk() {
        guard completion != nil, case .send(let source) = direction else { return }
        let chunk: Data
        do {
            chunk = try nextChunk(from: source)
        } catch {
            return finish(failure: .io(error.localizedDescription))
        }

        if chunk.isEmpty {
            // Half-close so the client sees EOF, then report success once the stack has it.
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { return self.finish(failure: .io(error.localizedDescription)) }
                self.connection.cancel()
                self.finish(failure: nil)
            })
            return
        }

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { return self.finish(failure: .io(error.localizedDescription)) }
            self.advance(by: chunk.count)
            self.sendNextChunk()
        })
    }

    private func nextChunk(from source: Source) throws -> Data {
        switch source {
        case .file(let handle):
            return try handle.read(upToCount: Self.chunkSize) ?? Data()
        case .data(let data):
            let end = min(dataOffset + Self.chunkSize, data.count)
            defer { dataOffset = end }
            return data.subdata(in: dataOffset..<end)
        }
    }

    private func receiveNextChunk(into handle: FileHandle) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] content, _, isComplete, error in
            guard let self, self.completion != nil else { return }
            if let content, !content.isEmpty {
                do {
                    try handle.write(contentsOf: content)
                } catch {
                    return self.finish(failure: .io(error.localizedDescription))
                }
                self.advance(by: content.count)
            }
            if let error {
                self.finish(failure: .io(error.localizedDescription))
            } else if isComplete {
                self.connection.cancel()
                self.finish(failure: nil)
            } else {
                self.receiveNextChunk(into: handle)
            }
        }
    }

    private func advance(by count: Int) {
        bytesTransferred += UInt64(count)
        let now = Date()
        if now.timeIntervalSince(lastProgress) >= Self.progressInterval {
            lastProgress = now
            progress(bytesTransferred)
        }
    }

    private func finish(failure: Failure?) {
        guard let completion else { return }
        self.completion = nil
        if failure != nil { connection.forceCancel() }
        completion(bytesTransferred, failure)
    }
}
