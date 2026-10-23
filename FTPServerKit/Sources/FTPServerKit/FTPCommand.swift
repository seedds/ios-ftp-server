import Foundation

struct FTPCommand: Equatable {
    let verb: String
    let argument: String

    init(verb: String, argument: String = "") {
        self.verb = verb
        self.argument = argument
    }

    init?(line: String) {
        let trimmed = line.drop { $0 == " " }
        guard !trimmed.isEmpty else { return nil }
        if let space = trimmed.firstIndex(of: " ") {
            verb = trimmed[..<space].uppercased()
            argument = String(trimmed[trimmed.index(after: space)...])
        } else {
            verb = trimmed.uppercased()
            argument = ""
        }
    }

    var loggable: String {
        if verb == "PASS" { return "PASS ****" }
        return argument.isEmpty ? verb : "\(verb) \(argument)"
    }
}

enum ControlLineDecoder {
    /// Removes Telnet IAC sequences (clients send `IAC IP IAC DM` before `ABOR`).
    static func stripTelnet(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0xFF, index + 1 < bytes.count else {
                output.append(byte)
                index += 1
                continue
            }
            let next = bytes[index + 1]
            if next == 0xFF {
                output.append(0xFF)
                index += 2
            } else {
                // WILL / WONT / DO / DONT carry an option byte.
                index += (251...254).contains(next) ? 3 : 2
            }
        }
        return output
    }

    static func decode(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }
}
