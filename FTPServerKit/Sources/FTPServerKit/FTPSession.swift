import Foundation
import Network

/// One client's control connection. All state is confined to `queue`; commands run strictly
/// one at a time, except `ABOR`, which interrupts the transfer in progress.
final class FTPSession: @unchecked Sendable {
    let id = UUID()

    private let control: NWConnection
    private let queue: DispatchQueue
    private let config: FTPServerConfiguration
    private let emit: @Sendable (FTPServerEvent) -> Void
    private let onClose: @Sendable (UUID) -> Void

    private var fs: VirtualFileSystem
    private var inputBuffer = Data()
    private var pendingCommands: [FTPCommand] = []
    private var isBusy = false
    private var isClosed = false
    private var didConnect = false

    private var pendingUser: String?
    private var username: String?
    private var failedLogins = 0
    private var asciiMode = false
    private var restartOffset: UInt64 = 0
    private var renameSource: VirtualFileSystem.ResolvedPath?

    private var dataConnection: DataConnection?
    private var openingDataConnection: DataConnection?
    private var activeTransfer: DataTransfer?
    private var idleTimer: DispatchSourceTimer?
    private var lastActivity = Date()

    private static let maxLineLength = 8 * 1024
    private static let commandsAllowedBeforeLogin: Set<String> = [
        "USER", "PASS", "QUIT", "SYST", "FEAT", "HELP", "NOOP", "OPTS", "AUTH", "PBSZ", "PROT", "CLNT",
    ]

    init(
        connection: NWConnection,
        configuration: FTPServerConfiguration,
        emit: @escaping @Sendable (FTPServerEvent) -> Void,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.control = connection
        self.config = configuration
        self.emit = emit
        self.onClose = onClose
        self.queue = DispatchQueue(label: "FTPSession")
        self.fs = VirtualFileSystem(root: configuration.rootDirectory)
    }

    func start() {
        control.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.connected()
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        control.start(queue: queue)
    }

    func shutdown() {
        queue.async { [self] in
            reply(421, "Server shutting down.")
            close()
        }
    }

    private func connected() {
        guard !didConnect else { return }
        didConnect = true
        let remote = control.endpoint.host?.displayString ?? "unknown"
        emit(.sessionOpened(FTPSessionInfo(id: id, remoteAddress: remote, connectedAt: Date())))
        log("Connected from \(remote)")
        reply(220, config.welcomeMessage)
        startIdleTimer()
        receive()
    }

    private func receive() {
        control.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        inputBuffer.append(data)
        while let newline = inputBuffer.firstIndex(of: 0x0A) {
            var bytes = [UInt8](inputBuffer[inputBuffer.startIndex..<newline])
            inputBuffer.removeSubrange(inputBuffer.startIndex...newline)
            if bytes.last == 0x0D { bytes.removeLast() }
            let line = ControlLineDecoder.decode(ControlLineDecoder.stripTelnet(bytes))
            if let command = FTPCommand(line: line) { enqueue(command) }
        }
        if inputBuffer.count > Self.maxLineLength {
            reply(500, "Command line too long.")
            close()
        }
    }

    private func enqueue(_ command: FTPCommand) {
        lastActivity = Date()
        if command.verb == "ABOR", isBusy, activeTransfer != nil || openingDataConnection != nil {
            log(command.loggable)
            abort()
            return
        }
        pendingCommands.append(command)
        processNextCommand()
    }

    private func processNextCommand() {
        guard !isBusy, !isClosed, !pendingCommands.isEmpty else { return }
        let command = pendingCommands.removeFirst()
        isBusy = true
        if command.verb != "NOOP" { log(command.loggable) }
        if execute(command) == .done { commandFinished() }
    }

    /// Ends the current command; the next one runs on a fresh turn of the queue so replies
    /// can never interleave.
    private func commandFinished() {
        isBusy = false
        lastActivity = Date()
        queue.async { [weak self] in self?.processNextCommand() }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        idleTimer?.cancel()
        idleTimer = nil
        activeTransfer?.cancel()
        activeTransfer = nil
        openingDataConnection?.close()
        dataConnection?.close()
        dataConnection = nil
        pendingCommands.removeAll()
        control.cancel()
        if didConnect {
            log("Disconnected")
            emit(.sessionClosed(sessionID: id))
        }
        onClose(id)
    }

    private func closeSoon() {
        queue.async { [weak self] in self?.close() }
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = min(30, max(1, config.idleTimeout / 2))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.activeTransfer == nil, self.openingDataConnection == nil else { return }
            if Date().timeIntervalSince(self.lastActivity) >= self.config.idleTimeout {
                self.log("Idle timeout")
                self.reply(421, "Timeout: closing control connection.")
                self.close()
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func reply(_ code: Int, _ text: String, then completion: (@Sendable () -> Void)? = nil) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var message = ""
        for (index, line) in lines.enumerated() {
            message += index == lines.count - 1 ? "\(code) \(line)\r\n" : "\(code)-\(line)\r\n"
        }
        send(message, then: completion)
    }

    private func reply(_ code: Int, header: String, body: [String], footer: String) {
        var message = "\(code)-\(header)\r\n"
        for line in body { message += " \(line)\r\n" }
        message += "\(code) \(footer)\r\n"
        send(message, then: nil)
    }

    private func send(_ message: String, then completion: (@Sendable () -> Void)?) {
        guard !isClosed else { return }
        control.send(content: Data(message.utf8), completion: .contentProcessed { _ in completion?() })
    }

    private func log(_ message: String) {
        emit(.log(sessionID: id, message: message))
    }

    private func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private enum Completion { case done, pending }

    private func execute(_ command: FTPCommand) -> Completion {
        let verb = command.verb
        let argument = command.argument

        guard username != nil || Self.commandsAllowedBeforeLogin.contains(verb) else {
            reply(530, "Please login with USER and PASS.")
            return .done
        }
        // RNTO must immediately follow RNFR.
        let pendingRename = renameSource
        renameSource = nil

        switch verb {
        case "USER": return user(argument)
        case "PASS": return pass(argument)
        case "QUIT":
            reply(221, "Goodbye.") { [weak self] in self?.closeSoon() }
            return .pending
        case "NOOP": reply(200, "NOOP ok.")
        case "SYST": reply(215, "UNIX Type: L8")
        case "FEAT":
            reply(211, header: "Features:", body: [
                "EPRT", "EPSV", "MDTM", "MFMT", "MLST type*;size*;modify*;perm*;",
                "PASV", "REST STREAM", "SIZE", "TVFS", "UTF8",
            ], footer: "End")
        case "HELP":
            reply(214, header: "The following commands are recognized:", body: [
                "ABOR APPE CDUP CWD  DELE EPRT EPSV FEAT HELP LIST MDTM MFMT MKD  MLSD MLST",
                "MODE NLST NOOP OPTS PASS PASV PORT PWD  QUIT REST RETR RMD  RNFR RNTO SIZE",
                "STAT STOR STOU STRU SYST TYPE USER XCUP XCWD XMKD XPWD XRMD",
            ], footer: "Help OK.")
        case "OPTS": opts(argument)
        case "CLNT": reply(200, "Noted.")
        case "AUTH", "PBSZ", "PROT", "CCC": reply(502, "TLS is not supported; use plain FTP.")
        case "TYPE": type(argument)
        case "MODE":
            argument.uppercased() == "S" ? reply(200, "Mode set to S.") : reply(504, "Only stream mode is supported.")
        case "STRU":
            argument.uppercased() == "F" ? reply(200, "Structure set to F.") : reply(504, "Only file structure is supported.")
        case "ALLO": reply(202, "ALLO not needed.")
        case "SITE":
            argument.uppercased().hasPrefix("CHMOD") ? reply(200, "SITE CHMOD ignored.") : reply(504, "SITE command not supported.")

        case "PWD", "XPWD": reply(257, "\(quoted(fs.currentDirectory)) is the current directory.")
        case "CWD", "XCWD": changeDirectory(argument)
        case "CDUP", "XCUP": changeDirectory("..")

        case "PASV": return passive(extended: false, argument)
        case "EPSV": return passive(extended: true, argument)
        case "PORT": port(argument)
        case "EPRT": extendedPort(argument)
        case "REST": restart(argument)
        case "ABOR": abort()

        case "LIST": return list(argument, format: .long)
        case "NLST": return list(argument, format: .names)
        case "MLSD": return list(argument, format: .machine)
        case "MLST": machineListSingle(argument)
        case "STAT": status(argument)
        case "SIZE": size(argument)
        case "MDTM": modificationTime(argument)
        case "MFMT": setModificationTime(argument)

        case "RETR": return retrieve(argument)
        case "STOR": return store(argument, mode: .overwrite)
        case "APPE": return store(argument, mode: .append)
        case "STOU": return store(argument, mode: .unique)

        case "DELE": delete(argument)
        case "MKD", "XMKD": makeDirectory(argument)
        case "RMD", "XRMD": removeDirectory(argument)
        case "RNFR": renameFrom(argument)
        case "RNTO": renameTo(argument, source: pendingRename)

        default: reply(502, "Command not implemented.")
        }
        return .done
    }

    private func isAnonymousName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "anonymous" || (lower == "ftp" && name != config.username)
    }

    private func user(_ name: String) -> Completion {
        username = nil
        pendingUser = name
        if config.allowAnonymous && isAnonymousName(name) {
            reply(331, "Anonymous login okay, send your e-mail address as password.")
        } else {
            reply(331, "Please specify the password.")
        }
        return .done
    }

    private func pass(_ password: String) -> Completion {
        guard let user = pendingUser else {
            reply(503, "Login with USER first.")
            return .done
        }
        pendingUser = nil
        let anonymous = config.allowAnonymous && isAnonymousName(user)
        let valid = !config.username.isEmpty && user == config.username && password == config.password
        if anonymous || valid {
            username = anonymous ? "anonymous" : user
            failedLogins = 0
            log("Logged in as \(username!)")
            emit(.sessionAuthenticated(sessionID: id, username: username!))
            reply(230, "Login successful.")
            return .done
        }

        failedLogins += 1
        log("Failed login for \(user)")
        // Answer slowly to make password guessing impractical.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isClosed else { return }
            if self.failedLogins >= self.config.maxLoginAttempts {
                self.reply(421, "Too many failed login attempts.") { [weak self] in self?.closeSoon() }
            } else {
                self.reply(530, "Login incorrect.")
                self.commandFinished()
            }
        }
        return .pending
    }

    private func opts(_ argument: String) {
        let upper = argument.uppercased()
        if upper.hasPrefix("UTF8") {
            reply(200, "Always in UTF8 mode.")
        } else if upper.hasPrefix("MLST") {
            reply(200, "MLST OPTS type;size;modify;perm;")
        } else {
            reply(501, "Option not understood.")
        }
    }

    private func type(_ argument: String) {
        switch argument.uppercased().split(separator: " ").first {
        case "A":
            asciiMode = true
            reply(200, "Switching to ASCII mode.")
        case "I", "L":
            asciiMode = false
            reply(200, "Switching to Binary mode.")
        default:
            reply(504, "Unsupported type.")
        }
    }

    private func changeDirectory(_ argument: String) {
        if fs.changeDirectory(to: argument.isEmpty ? "/" : argument) {
            reply(250, "Directory successfully changed.")
        } else {
            reply(550, "Failed to change directory.")
        }
    }

    private func restart(_ argument: String) {
        guard let offset = UInt64(argument.trimmingCharacters(in: .whitespaces)) else {
            reply(501, "REST requires a byte offset.")
            return
        }
        restartOffset = offset
        reply(350, "Restarting at \(offset). Send STOR or RETR.")
    }

    private func takeRestartOffset() -> UInt64 {
        defer { restartOffset = 0 }
        return restartOffset
    }

    private func status(_ argument: String) {
        if argument.isEmpty {
            reply(211, header: "FTP server status:", body: [
                "Connected to \(control.endpoint.host?.displayString ?? "unknown")",
                "Logged in as \(username ?? "nobody")",
                "TYPE: \(asciiMode ? "ASCII" : "BINARY")",
                activeTransfer == nil ? "No data connection" : "Transfer in progress",
            ], footer: "End of status.")
            return
        }
        guard let target = resolvePath(argument) else { return }
        guard let lines = listingLines(for: target, format: .long) else {
            reply(550, "No such file or directory.")
            return
        }
        reply(213, header: "Status of \(target.path):", body: lines, footer: "End of status.")
    }

    private func size(_ argument: String) {
        guard let target = resolvePath(argument) else { return }
        guard let entry = fs.entry(at: target.url), !entry.isDirectory else {
            reply(550, "Could not get file size.")
            return
        }
        reply(213, "\(entry.size)")
    }

    private func modificationTime(_ argument: String) {
        guard let target = resolvePath(argument) else { return }
        guard let entry = fs.entry(at: target.url) else {
            reply(550, "Could not get file modification time.")
            return
        }
        reply(213, ListingFormatter.timestamp(entry.modified))
    }

    private func setModificationTime(_ argument: String) {
        guard requireWritable() else { return }
        guard let space = argument.firstIndex(of: " "),
              let date = ListingFormatter.parseTimestamp(String(argument[..<space])) else {
            reply(501, "Usage: MFMT YYYYMMDDHHMMSS path")
            return
        }
        guard let target = resolvePath(String(argument[argument.index(after: space)...])) else { return }
        do {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.url.path)
            reply(213, "Modify=\(ListingFormatter.timestamp(date)); \(target.path)")
            emit(.fileSystemChanged(path: target.path))
        } catch {
            reply(550, "Could not set modification time.")
        }
    }

    private func machineListSingle(_ argument: String) {
        guard let target = resolvePath(argument.isEmpty ? "." : argument) else { return }
        guard let entry = fs.entry(at: target.url) else {
            reply(550, "No such file or directory.")
            return
        }
        let facts = ListingFormatter.machineFacts(for: entry, readOnly: config.readOnly, name: target.path)
        reply(250, header: "Listing \(target.path)", body: [facts], footer: "End.")
    }

    private func resolvePath(_ argument: String) -> VirtualFileSystem.ResolvedPath? {
        guard let path = fs.resolve(argument) else {
            reply(550, "Permission denied.")
            return nil
        }
        return path
    }

    private func requireWritable() -> Bool {
        if config.readOnly { reply(550, "Permission denied: server is read-only.") }
        return !config.readOnly
    }

    private func delete(_ argument: String) {
        guard requireWritable(), let target = resolvePath(argument) else { return }
        guard let entry = fs.entry(at: target.url), !entry.isDirectory else {
            reply(550, "Delete operation failed: not a file.")
            return
        }
        do {
            try FileManager.default.removeItem(at: target.url)
            reply(250, "Delete operation successful.")
            emit(.fileSystemChanged(path: target.path))
        } catch {
            reply(550, "Delete operation failed.")
        }
    }

    private func makeDirectory(_ argument: String) {
        guard requireWritable(), let target = resolvePath(argument) else { return }
        guard !fs.exists(target.url) else {
            reply(550, "Create directory operation failed: already exists.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: false)
            reply(257, "\(quoted(target.path)) created.")
            emit(.fileSystemChanged(path: target.path))
        } catch {
            reply(550, "Create directory operation failed.")
        }
    }

    private func removeDirectory(_ argument: String) {
        guard requireWritable(), let target = resolvePath(argument) else { return }
        guard !target.isRoot, fs.isDirectory(target.url) else {
            reply(550, "Remove directory operation failed.")
            return
        }
        guard (try? FileManager.default.contentsOfDirectory(atPath: target.url.path).isEmpty) == true else {
            reply(550, "Remove directory operation failed: directory not empty.")
            return
        }
        do {
            try FileManager.default.removeItem(at: target.url)
            reply(250, "Remove directory operation successful.")
            emit(.fileSystemChanged(path: target.path))
        } catch {
            reply(550, "Remove directory operation failed.")
        }
    }

    private func renameFrom(_ argument: String) {
        guard requireWritable(), let source = resolvePath(argument) else { return }
        guard !source.isRoot, fs.exists(source.url) else {
            reply(550, "RNFR command failed.")
            return
        }
        renameSource = source
        reply(350, "Ready for RNTO.")
    }

    private func renameTo(_ argument: String, source: VirtualFileSystem.ResolvedPath?) {
        guard let source else {
            reply(503, "RNFR required first.")
            return
        }
        guard requireWritable(), let destination = resolvePath(argument) else { return }
        guard !destination.isRoot else {
            reply(550, "Rename failed.")
            return
        }
        do {
            if fs.exists(destination.url), destination.url.standardizedFileURL != source.url.standardizedFileURL {
                // Like rename(2): a file may replace a file, nothing else may be replaced.
                guard !fs.isDirectory(destination.url), !fs.isDirectory(source.url) else {
                    reply(550, "Rename failed: destination exists.")
                    return
                }
                try FileManager.default.removeItem(at: destination.url)
            }
            try FileManager.default.moveItem(at: source.url, to: destination.url)
            reply(250, "Rename successful.")
            emit(.fileSystemChanged(path: destination.path))
        } catch {
            reply(550, "Rename failed.")
        }
    }

    private func passive(extended: Bool, _ argument: String) -> Completion {
        if extended && argument.uppercased() == "ALL" {
            reply(200, "EPSV ALL ok.")
            return .done
        }
        let ipv4 = extended ? nil : control.currentPath?.localEndpoint?.host?.ipv4Address
            ?? NetworkAddresses.localAddresses().first.flatMap { IPv4Address($0.address) }
        if !extended {
            guard ipv4 != nil else {
                reply(425, "PASV is unavailable on this connection; use EPSV.")
                return .done
            }
        }

        dataConnection?.close()
        dataConnection = nil
        DataConnection.passive(queue: queue, allowedPeer: control.endpoint.host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (channel, port)):
                guard !self.isClosed else { return channel.close() }
                self.dataConnection = channel
                if let ipv4 {
                    let octets = ipv4.rawValue.map(String.init).joined(separator: ",")
                    self.reply(227, "Entering Passive Mode (\(octets),\(port >> 8),\(port & 0xFF)).")
                } else {
                    self.reply(229, "Entering Extended Passive Mode (|||\(port)|).")
                }
            case .failure(let error):
                self.reply(425, "Can't open passive connection: \(error.localizedDescription)")
            }
            self.commandFinished()
        }
        return .pending
    }

    private func port(_ argument: String) {
        let numbers = argument.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6, let address = IPv4Address(Data(numbers[0..<4])) else {
            reply(501, "Illegal PORT command.")
            return
        }
        activeMode(host: .ipv4(address), port: UInt16(numbers[4]) << 8 | UInt16(numbers[5]))
    }

    private func extendedPort(_ argument: String) {
        // |1|192.168.1.2|6275|  or  |2|fe80::1|6275|
        guard let delimiter = argument.first else {
            reply(501, "Illegal EPRT command.")
            return
        }
        let fields = argument.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, let port = UInt16(fields[3]) else {
            reply(501, "Illegal EPRT command.")
            return
        }
        let host: NWEndpoint.Host
        switch fields[1] {
        case "1":
            guard let address = IPv4Address(fields[2]) else { return reply(501, "Illegal EPRT address.") }
            host = .ipv4(address)
        case "2":
            guard let address = IPv6Address(fields[2]) else { return reply(501, "Illegal EPRT address.") }
            host = .ipv6(address)
        default:
            return reply(522, "Network protocol not supported, use (1,2).")
        }
        activeMode(host: host, port: port)
    }

    private func activeMode(host: NWEndpoint.Host, port: UInt16) {
        // Only connect back to the client itself, on an unprivileged port (prevents FTP bounce attacks).
        guard port >= 1024, let endpointPort = NWEndpoint.Port(rawValue: port),
              host.normalizedAddress != nil,
              host.normalizedAddress == control.endpoint.host?.normalizedAddress else {
            reply(500, "Illegal PORT command: address must be your own.")
            return
        }
        dataConnection?.close()
        dataConnection = DataConnection.active(queue: queue, endpoint: .hostPort(host: host, port: endpointPort))
        reply(200, "PORT command successful. Consider using PASV.")
    }

    private func abort() {
        // Cancelling makes the interrupted command reply 426 before ABOR replies 226.
        if let transfer = activeTransfer {
            transfer.cancel()
        } else if let opening = openingDataConnection {
            opening.close()
        } else {
            dataConnection?.close()
            dataConnection = nil
            reply(225, "No transfer to abort.")
            return
        }
        reply(226, "Abort successful.")
    }

    private enum ListFormat { case long, names, machine }

    private func listingLines(for target: VirtualFileSystem.ResolvedPath, format: ListFormat) -> [String]? {
        if fs.isDirectory(target.url) {
            guard let entries = try? fs.contents(of: target.url) else { return nil }
            return entries.map { line(for: $0, format: format) }
        }
        guard let entry = fs.entry(at: target.url) else { return nil }
        return [line(for: entry, format: format)]
    }

    private func line(for entry: VirtualFileSystem.Entry, format: ListFormat) -> String {
        switch format {
        case .long: return ListingFormatter.unixLine(for: entry)
        case .names: return entry.name
        case .machine: return ListingFormatter.machineFacts(for: entry, readOnly: config.readOnly)
        }
    }

    private func list(_ argument: String, format: ListFormat) -> Completion {
        _ = takeRestartOffset()
        // Clients send `ls` flags such as `LIST -la`; drop them, keep the path.
        var path = Substring(argument)
        while path.hasPrefix("-") {
            path = path.firstIndex(of: " ").map { path[path.index(after: $0)...] } ?? ""
        }
        guard let target = resolvePath(path.isEmpty ? "." : String(path)) else { return .done }
        if format == .machine && !fs.isDirectory(target.url) {
            reply(501, "MLSD requires a directory.")
            return .done
        }
        guard let lines = listingLines(for: target, format: format) else {
            reply(550, "No such file or directory.")
            return .done
        }
        let data = Data(lines.map { $0 + "\r\n" }.joined().utf8)
        return transfer(.send(.data(data)), opening: "Here comes the directory listing.", info: nil) {}
    }

    private func retrieve(_ argument: String) -> Completion {
        let offset = takeRestartOffset()
        guard let target = resolvePath(argument) else { return .done }
        guard let entry = fs.entry(at: target.url), !entry.isDirectory,
              let handle = try? FileHandle(forReadingFrom: target.url) else {
            reply(550, "Failed to open file.")
            return .done
        }
        guard offset <= entry.size else {
            try? handle.close()
            reply(554, "Restart offset \(offset) is beyond the end of the file (\(entry.size) bytes).")
            return .done
        }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            try? handle.close()
            reply(551, "Failed to seek in file.")
            return .done
        }
        let info = FTPTransferInfo(
            id: UUID(), sessionID: id, direction: .download, path: target.path,
            startOffset: offset, expectedSize: entry.size, startDate: Date()
        )
        let message = offset > 0
            ? "Opening BINARY mode data connection for \(target.name) (\(entry.size) bytes), resuming at \(offset)."
            : "Opening BINARY mode data connection for \(target.name) (\(entry.size) bytes)."
        return transfer(.send(.file(handle)), opening: message, info: info) {
            try? handle.close()
        }
    }

    private enum StoreMode { case overwrite, append, unique }

    private func store(_ argument: String, mode: StoreMode) -> Completion {
        let offset = takeRestartOffset()
        guard requireWritable() else { return .done }
        guard var target = resolvePath(argument.isEmpty && mode == .unique ? "file" : argument) else { return .done }
        if mode == .unique, let unique = uniquePath(near: target) {
            target = unique
        }
        let parent = target.url.deletingLastPathComponent()
        guard !target.isRoot, !fs.isDirectory(target.url), fs.isDirectory(parent) else {
            reply(553, "Could not create file.")
            return .done
        }

        let handle: FileHandle
        let startOffset: UInt64
        do {
            if !fs.exists(target.url) {
                guard FileManager.default.createFile(atPath: target.url.path, contents: nil) else {
                    reply(553, "Could not create file.")
                    return .done
                }
            }
            handle = try FileHandle(forWritingTo: target.url)
            switch mode {
            case .append:
                startOffset = try handle.seekToEnd()
            case .overwrite, .unique:
                let size = try handle.seekToEnd()
                guard offset <= size else {
                    try? handle.close()
                    reply(554, "Restart offset \(offset) is beyond the end of the file (\(size) bytes).")
                    return .done
                }
                // Resuming keeps the first `offset` bytes; a plain STOR replaces the file.
                try handle.truncate(atOffset: offset)
                startOffset = offset
            }
        } catch {
            reply(553, "Could not open file for writing.")
            return .done
        }

        let info = FTPTransferInfo(
            id: UUID(), sessionID: id, direction: .upload, path: target.path,
            startOffset: startOffset, expectedSize: nil, startDate: Date()
        )
        let message: String
        switch mode {
        case .unique: message = "FILE: \(target.name)"
        case .append: message = "Ok to append to \(target.name) at \(startOffset)."
        case .overwrite: message = startOffset > 0 ? "Ok to resume \(target.name) at \(startOffset)." : "Ok to send data."
        }
        let path = target.path
        return transfer(.receive(handle), opening: message, info: info) { [weak self] in
            try? handle.synchronize()
            try? handle.close()
            // Partial uploads are kept on purpose so the client can resume them.
            self?.emit(.fileSystemChanged(path: path))
        }
    }

    private func uniquePath(near target: VirtualFileSystem.ResolvedPath) -> VirtualFileSystem.ResolvedPath? {
        guard fs.exists(target.url) else { return target }
        for suffix in 1...9999 {
            if let candidate = fs.resolve(target.path + ".\(suffix)"), !fs.exists(candidate.url) {
                return candidate
            }
        }
        return nil
    }

    private func transfer(
        _ direction: DataTransfer.Direction,
        opening message: String,
        info: FTPTransferInfo?,
        cleanup: @escaping () -> Void
    ) -> Completion {
        guard let channel = dataConnection else {
            cleanup()
            reply(425, "Use PASV, EPSV, PORT or EPRT first.")
            return .done
        }
        dataConnection = nil
        openingDataConnection = channel
        reply(150, message)

        channel.open(timeout: config.dataConnectionTimeout) { [weak self] result in
            guard let self else { return }
            self.openingDataConnection = nil
            let connection: NWConnection
            switch result {
            case .success(let opened):
                connection = opened
            case .failure(let error):
                channel.close()
                cleanup()
                if case .cancelled = error {
                    self.reply(426, "Connection closed; transfer aborted.")
                } else {
                    self.reply(425, "Can't open data connection: \(error.localizedDescription)")
                }
                return self.commandFinished()
            }

            if let info { self.emit(.transferStarted(info)) }
            let transfer = DataTransfer(
                connection: connection,
                direction: direction,
                progress: { [weak self] bytes in
                    guard let info else { return }
                    self?.emit(.transferProgress(transferID: info.id, bytesTransferred: bytes))
                },
                completion: { [weak self] bytes, failure in
                    channel.close()
                    cleanup()
                    guard let self else { return }
                    self.activeTransfer = nil
                    self.finishTransfer(info: info, bytes: bytes, failure: failure)
                }
            )
            self.activeTransfer = transfer
            transfer.start()
        }
        return .pending
    }

    private func finishTransfer(info: FTPTransferInfo?, bytes: UInt64, failure: DataTransfer.Failure?) {
        let outcome: FTPTransferOutcome
        switch failure {
        case nil:
            outcome = .completed
            reply(226, "Transfer complete.")
        case .aborted:
            outcome = .aborted
            reply(426, "Connection closed; transfer aborted.")
        case .io(let reason):
            outcome = .failed(reason)
            reply(451, "Transfer failed: \(reason)")
        }
        if let info {
            let total = info.startOffset + bytes
            switch outcome {
            case .completed:
                log("\(info.direction == .upload ? "Uploaded" : "Downloaded") \(info.path) (\(total) bytes)")
            case .aborted:
                log("Transfer of \(info.path) aborted")
            case .failed(let reason):
                log("Transfer of \(info.path) failed: \(reason)")
            }
            emit(.transferEnded(transferID: info.id, bytesTransferred: bytes, outcome: outcome))
        }
        commandFinished()
    }
}
