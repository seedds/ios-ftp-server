import Foundation
@testable import FTPServerKit

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class ServerHarness: @unchecked Sendable {
    static let user = "tester"
    static let password = "s3cret"

    let root: URL
    let server: FTPServer
    let port: UInt16
    let events = Locked<[FTPServerEvent]>([])

    init(readOnly: Bool = false, allowAnonymous: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FTPServerKitTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let configuration = FTPServerConfiguration(
            port: 0, rootDirectory: root, username: Self.user, password: Self.password,
            allowAnonymous: allowAnonymous, readOnly: readOnly, dataConnectionTimeout: 5
        )
        let ready = DispatchSemaphore(value: 0)
        let state = Locked<FTPServerState>(.stopped)
        let events = self.events
        server = FTPServer(configuration: configuration, eventQueue: DispatchQueue(label: "test-events")) { event in
            events.withLock { $0.append(event) }
            if case .stateChanged(let newState) = event, newState != .starting {
                state.withLock { $0 = newState }
                ready.signal()
            }
        }
        server.start()
        guard ready.wait(timeout: .now() + 5) == .success,
              case .running(let port) = state.withLock({ $0 }) else {
            throw TestError("server did not start: \(state.withLock { $0 })")
        }
        self.port = port
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ data: Data, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func read(_ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    func client(login: Bool = true) throws -> TestClient {
        let client = try TestClient(port: port)
        _ = try client.expect(220)
        if login {
            try client.command("USER \(Self.user)", expect: 331)
            try client.command("PASS \(Self.password)", expect: 230)
            try client.command("TYPE I", expect: 200)
        }
        return client
    }
}

func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
}

struct Reply {
    let code: Int
    let text: String
}

final class TestClient {
    private let control: Int32
    private var buffer: [UInt8] = []

    init(port: UInt16) throws {
        control = try Self.connect(port: port)
    }

    deinit { Darwin.close(control) }

    static func connect(port: UInt16, host: String = "127.0.0.1") throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestError("socket failed") }
        configure(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw TestError("connect to \(port) failed: errno \(errno)")
        }
        return fd
    }

    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ line: String) throws {
        try Self.writeAll(control, Data((line + "\r\n").utf8))
    }

    func sendRaw(_ bytes: [UInt8]) throws {
        try Self.writeAll(control, Data(bytes))
    }

    @discardableResult
    func command(_ line: String, expect code: Int? = nil) throws -> Reply {
        try send(line)
        let reply = try readReply()
        if let code, reply.code != code {
            throw TestError("\(line) → expected \(code), got \(reply.code) \(reply.text)")
        }
        return reply
    }

    @discardableResult
    func expect(_ code: Int) throws -> Reply {
        let reply = try readReply()
        guard reply.code == code else { throw TestError("expected \(code), got \(reply.code) \(reply.text)") }
        return reply
    }

    func readReply() throws -> Reply {
        let first = try readLine()
        guard first.count >= 4, let code = Int(first.prefix(3)) else { throw TestError("malformed reply: \(first)") }
        var lines = [first]
        if first.dropFirst(3).first == "-" {
            while !lines.last!.hasPrefix("\(code) ") {
                lines.append(try readLine())
            }
        }
        return Reply(code: code, text: lines.joined(separator: "\n"))
    }

    private func readLine() throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = recv(control, &chunk, chunk.count, 0)
            guard count > 0 else { throw TestError("control connection closed (errno \(errno))") }
            buffer += chunk[0..<count]
        }
    }

    func openDataConnection(extended: Bool = true) throws -> Int32 {
        let port: UInt16
        if extended {
            let reply = try command("EPSV", expect: 229)
            guard let start = reply.text.range(of: "(|||"), let end = reply.text.range(of: "|)"),
                  let value = UInt16(reply.text[start.upperBound..<end.lowerBound]) else {
                throw TestError("bad EPSV reply \(reply.text)")
            }
            port = value
        } else {
            let reply = try command("PASV", expect: 227)
            guard let open = reply.text.firstIndex(of: "("), let close = reply.text.firstIndex(of: ")") else {
                throw TestError("bad PASV reply \(reply.text)")
            }
            let numbers = reply.text[reply.text.index(after: open)..<close].split(separator: ",").compactMap { UInt16($0) }
            guard numbers.count == 6 else { throw TestError("bad PASV reply \(reply.text)") }
            port = numbers[4] << 8 | numbers[5]
        }
        return try Self.connect(port: port)
    }

    func retrieve(_ path: String, offset: UInt64 = 0, extended: Bool = true) throws -> Data {
        let data = try openDataConnection(extended: extended)
        defer { Darwin.close(data) }
        if offset > 0 { try command("REST \(offset)", expect: 350) }
        try command("RETR \(path)", expect: 150)
        let content = try Self.readAll(data)
        try expect(226)
        return content
    }

    @discardableResult
    func store(_ path: String, _ content: Data, verb: String = "STOR", offset: UInt64 = 0) throws -> Reply {
        let data = try openDataConnection()
        if offset > 0 { try command("REST \(offset)", expect: 350) }
        let opening = try command("\(verb) \(path)", expect: 150)
        try Self.writeAll(data, content)
        Darwin.close(data)
        try expect(226)
        return opening
    }

    func list(_ verb: String = "LIST", _ path: String = "") throws -> String {
        let data = try openDataConnection()
        defer { Darwin.close(data) }
        try command(path.isEmpty ? verb : "\(verb) \(path)", expect: 150)
        let content = try Self.readAll(data)
        try expect(226)
        return String(decoding: content, as: UTF8.self)
    }

    static func readAll(_ fd: Int32) throws -> Data {
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count == 0 { return result }
            guard count > 0 else { throw TestError("data read failed (errno \(errno))") }
            result.append(contentsOf: chunk[0..<count])
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                guard written > 0 else { throw TestError("write failed (errno \(errno))") }
                offset += written
            }
        }
    }
}
