import Foundation

public struct FTPServerConfiguration: Sendable {
    public var port: UInt16
    public var rootDirectory: URL
    public var username: String
    public var password: String
    public var allowAnonymous: Bool
    public var readOnly: Bool
    public var bonjourName: String?
    public var welcomeMessage: String
    public var idleTimeout: TimeInterval
    public var dataConnectionTimeout: TimeInterval
    public var maxConnections: Int
    public var maxLoginAttempts: Int

    public init(
        port: UInt16 = 2121,
        rootDirectory: URL,
        username: String = "ftp",
        password: String = "",
        allowAnonymous: Bool = false,
        readOnly: Bool = false,
        bonjourName: String? = nil,
        welcomeMessage: String = "FTP server ready.",
        idleTimeout: TimeInterval = 600,
        dataConnectionTimeout: TimeInterval = 30,
        maxConnections: Int = 16,
        maxLoginAttempts: Int = 5
    ) {
        self.port = port
        self.rootDirectory = rootDirectory
        self.username = username
        self.password = password
        self.allowAnonymous = allowAnonymous
        self.readOnly = readOnly
        self.bonjourName = bonjourName
        self.welcomeMessage = welcomeMessage
        self.idleTimeout = idleTimeout
        self.dataConnectionTimeout = dataConnectionTimeout
        self.maxConnections = maxConnections
        self.maxLoginAttempts = maxLoginAttempts
    }
}
