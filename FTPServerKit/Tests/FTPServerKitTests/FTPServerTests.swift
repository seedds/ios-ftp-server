import Foundation
import Testing
@testable import FTPServerKit

@Suite("Login")
struct LoginTests {
    @Test func rejectsWrongPasswordAndCommandsBeforeLogin() throws {
        let harness = try ServerHarness()
        let client = try harness.client(login: false)
        try client.command("LIST", expect: 530)
        try client.command("USER \(ServerHarness.user)", expect: 331)
        try client.command("PASS wrong", expect: 530)
        try client.command("USER anonymous", expect: 331)
        try client.command("PASS me@example.com", expect: 530)
        try client.command("USER \(ServerHarness.user)", expect: 331)
        try client.command("PASS \(ServerHarness.password)", expect: 230)
        try client.command("PWD", expect: 257)
    }

    @Test func anonymousLoginWhenEnabled() throws {
        let harness = try ServerHarness(allowAnonymous: true)
        let client = try harness.client(login: false)
        try client.command("USER anonymous", expect: 331)
        try client.command("PASS guest@example.com", expect: 230)
    }

    @Test func disconnectsAfterTooManyFailures() throws {
        let harness = try ServerHarness()
        let client = try harness.client(login: false)
        for _ in 0..<4 {
            try client.command("USER x", expect: 331)
            try client.command("PASS y", expect: 530)
        }
        try client.command("USER x", expect: 331)
        try client.command("PASS y", expect: 421)
    }

    @Test func featuresAdvertiseResume() throws {
        let harness = try ServerHarness()
        let client = try harness.client()
        let features = try client.command("FEAT", expect: 211)
        #expect(features.text.contains("REST STREAM"))
        #expect(features.text.contains("MLST"))
        #expect(features.text.contains("UTF8"))
        try client.command("SYST", expect: 215)
        try client.command("OPTS UTF8 ON", expect: 200)
        try client.command("QUIT", expect: 221)
    }
}

@Suite("Transfers")
struct TransferTests {
    @Test func uploadThenDownloadRoundTrip() throws {
        let harness = try ServerHarness()
        let client = try harness.client()
        let content = randomData(3 * 1024 * 1024 + 17)

        try client.store("big.bin", content)
        #expect(try harness.read("big.bin") == content)
        #expect(try client.command("SIZE big.bin", expect: 213).text == "213 \(content.count)")
        #expect(try client.retrieve("big.bin") == content)
        #expect(try client.retrieve("/big.bin", extended: false) == content)
    }

    @Test func storeReplacesExistingFile() throws {
        let harness = try ServerHarness()
        try harness.write(randomData(10_000), to: "file.txt")
        let client = try harness.client()
        try client.store("file.txt", Data("short".utf8))
        #expect(try harness.read("file.txt") == Data("short".utf8))
    }

    @Test func resumeDownloadWithRest() throws {
        let harness = try ServerHarness()
        let content = randomData(500_000)
        try harness.write(content, to: "movie.mp4")
        let client = try harness.client()

        #expect(try client.retrieve("movie.mp4", offset: 123_457) == content.subdata(in: 123_457..<content.count))
        #expect(try client.retrieve("movie.mp4", offset: UInt64(content.count)).isEmpty)

        _ = try client.openDataConnection()
        try client.command("REST \(content.count + 1)", expect: 350)
        try client.command("RETR movie.mp4", expect: 554)
    }

    @Test func resumeUploadWithRestAndStor() throws {
        let harness = try ServerHarness()
        let content = randomData(800_000)
        let client = try harness.client()

        try client.store("photo.raw", content.subdata(in: 0..<300_000))
        // A partial upload is resumed from an offset; stale bytes past it are dropped.
        try harness.write(content.subdata(in: 0..<300_000) + Data(repeating: 0xEE, count: 1000), to: "photo.raw")
        let opening = try client.store("photo.raw", content.subdata(in: 250_000..<content.count), offset: 250_000)
        #expect(opening.text.contains("resume"))
        #expect(try harness.read("photo.raw") == content)
    }

    @Test func resumeUploadWithAppe() throws {
        let harness = try ServerHarness()
        let content = randomData(400_000)
        let client = try harness.client()

        try client.store("log.bin", content.subdata(in: 0..<123_456))
        let size = try client.command("SIZE log.bin", expect: 213).text.dropFirst(4)
        #expect(size == "123456")
        try client.store("log.bin", content.subdata(in: 123_456..<content.count), verb: "APPE")
        #expect(try harness.read("log.bin") == content)

        try client.store("new.bin", Data("abc".utf8), verb: "APPE")
        #expect(try harness.read("new.bin") == Data("abc".utf8))
    }

    @Test func storeUniqueNeverOverwrites() throws {
        let harness = try ServerHarness()
        try harness.write(Data("original".utf8), to: "a.txt")
        let client = try harness.client()
        let opening = try client.store("a.txt", Data("copy".utf8), verb: "STOU")
        #expect(opening.text.contains("FILE: a.txt.1"))
        #expect(try harness.read("a.txt") == Data("original".utf8))
        #expect(try harness.read("a.txt.1") == Data("copy".utf8))
    }

    @Test func activeModeWithPort() throws {
        let harness = try ServerHarness()
        try harness.write(Data("hello active".utf8), to: "active.txt")
        let client = try harness.client()

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(listener, $0, length)
                _ = getsockname(listener, $0, &length)
            }
        }
        listen(listener, 1)
        let port = UInt16(bigEndian: address.sin_port)

        try client.command("PORT 127,0,0,1,\(port >> 8),\(port & 0xFF)", expect: 200)
        try client.command("RETR active.txt", expect: 150)
        let data = accept(listener, nil, nil)
        defer { close(data) }
        TestClient.configure(data)
        #expect(try TestClient.readAll(data) == Data("hello active".utf8))
        try client.expect(226)

        try client.command("PORT 10,1,2,3,40,0", expect: 500)
        try client.command("EPRT |1|127.0.0.1|80|", expect: 500)
    }

    @Test func abortStopsDownload() throws {
        let harness = try ServerHarness()
        try harness.write(Data(repeating: 0xAB, count: 64 * 1024 * 1024), to: "huge.bin")
        let client = try harness.client()
        let data = try client.openDataConnection()
        defer { close(data) }
        try client.command("RETR huge.bin", expect: 150)
        var chunk = [UInt8](repeating: 0, count: 4096)
        #expect(recv(data, &chunk, chunk.count, 0) > 0)

        // Clients typically prefix ABOR with Telnet "interrupt process" + "data mark".
        try client.sendRaw([0xFF, 0xF4, 0xFF, 0xF2] + Array("ABOR\r\n".utf8))
        try client.expect(426)
        try client.expect(226)
        try client.command("NOOP", expect: 200)

        let ended = harness.events.withLock { events in
            events.contains { if case .transferEnded(_, _, .aborted) = $0 { return true } else { return false } }
        }
        #expect(ended)
    }

    @Test func reportsTransferEvents() throws {
        let harness = try ServerHarness()
        let client = try harness.client()
        try client.store("events.bin", randomData(1000))
        try client.command("NOOP", expect: 200)   // events are delivered asynchronously
        Thread.sleep(forTimeInterval: 0.2)

        let events = harness.events.withLock { $0 }
        let started = events.compactMap { if case .transferStarted(let info) = $0 { return info } else { return nil } }
        #expect(started.count == 1)
        #expect(started.first?.path == "/events.bin")
        #expect(started.first?.direction == .upload)
        #expect(events.contains {
            if case .transferEnded(_, 1000, .completed) = $0 { return true } else { return false }
        })
    }

    @Test func transferWithoutDataConnectionFails() throws {
        let harness = try ServerHarness()
        try harness.write(Data("x".utf8), to: "x.txt")
        let client = try harness.client()
        try client.command("RETR x.txt", expect: 425)
        try client.command("RETR missing.txt", expect: 550)
    }
}

@Suite("File system")
struct FileSystemTests {
    @Test func directoryOperations() throws {
        let harness = try ServerHarness()
        let client = try harness.client()

        try client.command("MKD Photos", expect: 257)
        try client.command("MKD Photos", expect: 550)
        try client.command("CWD Photos", expect: 250)
        #expect(try client.command("PWD", expect: 257).text == "257 \"/Photos\" is the current directory.")
        try client.store("Summer 2026.jpg", Data("jpeg".utf8))
        #expect(try harness.read("Photos/Summer 2026.jpg") == Data("jpeg".utf8))

        try client.command("CDUP", expect: 250)
        let listing = try client.list("LIST", "-la Photos")
        #expect(listing.contains("Summer 2026.jpg"))
        #expect(listing.hasPrefix("-rw-r--r--"))
        #expect(try client.list("NLST", "Photos") == "Summer 2026.jpg\r\n")
        let machine = try client.list("MLSD")
        #expect(machine.contains("type=dir;"))
        #expect(machine.hasSuffix(" Photos\r\n"))
        #expect(try client.command("MLST Photos/Summer 2026.jpg", expect: 250).text.contains("type=file;size=4;"))

        try client.command("RNFR Photos/Summer 2026.jpg", expect: 350)
        try client.command("RNTO /beach.jpg", expect: 250)
        #expect(try harness.read("beach.jpg") == Data("jpeg".utf8))
        try client.command("RNTO other.jpg", expect: 503)

        try client.command("RMD /", expect: 550)
        try client.command("DELE Photos", expect: 550)
        try client.command("RMD Photos", expect: 250)
        try client.command("DELE beach.jpg", expect: 250)
        try client.command("CWD Photos", expect: 550)
        #expect(try client.list().isEmpty)
    }

    @Test func modificationTimes() throws {
        let harness = try ServerHarness()
        try harness.write(Data("x".utf8), to: "t.txt")
        let client = try harness.client()
        try client.command("MFMT 20240229123456 t.txt", expect: 213)
        #expect(try client.command("MDTM t.txt", expect: 213).text == "213 20240229123456")
        try client.command("MFMT notadate t.txt", expect: 501)
        let status = try client.command("STAT t.txt", expect: 213)
        #expect(status.text.contains("t.txt"))
        try client.command("STAT", expect: 211)
    }

    @Test func cannotEscapeRoot() throws {
        let harness = try ServerHarness()
        try harness.write(Data("ok".utf8), to: "inside.txt")
        try FileManager.default.createSymbolicLink(atPath: harness.root.appendingPathComponent("escape").path, withDestinationPath: "/etc")
        let client = try harness.client()

        try client.command("CWD ../../../..", expect: 250)
        #expect(try client.command("PWD", expect: 257).text.contains("\"/\""))
        #expect(try client.retrieve("../../inside.txt") == Data("ok".utf8))
        _ = try client.openDataConnection()
        try client.command("RETR ../../../../etc/hosts", expect: 550)
        try client.command("CWD escape", expect: 550)
        try client.command("SIZE escape/hosts", expect: 550)
    }

    @Test func readOnlyServerRejectsWrites() throws {
        let harness = try ServerHarness(readOnly: true)
        try harness.write(Data("data".utf8), to: "keep.txt")
        let client = try harness.client()

        #expect(try client.retrieve("keep.txt") == Data("data".utf8))
        _ = try client.openDataConnection()
        try client.command("STOR new.txt", expect: 550)
        try client.command("DELE keep.txt", expect: 550)
        try client.command("MKD dir", expect: 550)
        try client.command("RNFR keep.txt", expect: 550)
        #expect(try harness.read("keep.txt") == Data("data".utf8))
    }
}

@Suite("Parsing")
struct ParsingTests {
    @Test func commandParsing() {
        #expect(FTPCommand(line: "retr my file.txt") == FTPCommand(verb: "RETR", argument: "my file.txt"))
        #expect(FTPCommand(line: "PWD") == FTPCommand(verb: "PWD"))
        #expect(FTPCommand(line: "") == nil)
        #expect(FTPCommand(line: "PASS hunter2")?.loggable == "PASS ****")
    }

    @Test func telnetStripping() {
        #expect(ControlLineDecoder.stripTelnet([0xFF, 0xF4, 0xFF, 0xF2, 65]) == [65])
        #expect(ControlLineDecoder.stripTelnet([0xFF, 0xFB, 0x01, 66]) == [66])
        #expect(ControlLineDecoder.stripTelnet([67, 0xFF, 0xFF]) == [67, 0xFF])
    }

    @Test func pathResolution() {
        var fs = VirtualFileSystem(root: URL(fileURLWithPath: "/tmp/does-not-matter"))
        #expect(fs.resolve("a/b/../c")?.path == "/a/c")
        #expect(fs.resolve("../../..")?.path == "/")
        #expect(fs.resolve("/x/./y/")?.path == "/x/y")
        #expect(fs.resolve("bad\0name") == nil)
        #expect(fs.changeDirectory(to: "/nope") == false)
        #expect(fs.currentDirectory == "/")
    }

    @Test func timestamps() {
        let date = ListingFormatter.parseTimestamp("20261022132400.123")
        #expect(date != nil)
        #expect(ListingFormatter.timestamp(date!) == "20261022132400")
        #expect(ListingFormatter.parseTimestamp("2026") == nil)
    }
}
