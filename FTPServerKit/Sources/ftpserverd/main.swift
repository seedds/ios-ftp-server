// Usage: swift run ftpserverd [directory] [port] [user] [password]   (no user: anonymous only)

import Foundation
import FTPServerKit

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath)
let port = arguments.count > 2 ? UInt16(arguments[2]) ?? 2121 : 2121
let user = arguments.count > 3 ? arguments[3] : ""
let password = arguments.count > 4 ? arguments[4] : ""

let configuration = FTPServerConfiguration(
    port: port,
    rootDirectory: root,
    username: user,
    password: password,
    allowAnonymous: user.isEmpty
)

let server = FTPServer(configuration: configuration, eventQueue: DispatchQueue(label: "events")) { event in
    switch event {
    case .stateChanged(.running(let port)):
        print("Serving \(root.path) on port \(port)")
        for address in NetworkAddresses.localAddresses() {
            print("  ftp://\(address.address):\(port)  (\(address.displayName))")
        }
    case .stateChanged(.failed(let reason)):
        print("Failed: \(reason)")
        exit(1)
    case .log(_, let message):
        print(message)
    default:
        break
    }
    fflush(stdout)
}
server.start()

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    server.stop()
    exit(0)
}
interrupt.resume()
dispatchMain()
