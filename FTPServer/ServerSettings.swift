import Foundation
import Observation
import Security

@Observable
@MainActor
final class ServerSettings {
    private enum Key {
        static let port = "port"
        static let username = "username"
        static let allowAnonymous = "allowAnonymous"
        static let readOnly = "readOnly"
        static let bonjourEnabled = "bonjourEnabled"
        static let keepScreenAwake = "keepScreenAwake"
        static let startOnLaunch = "startOnLaunch"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var port: Int { didSet { defaults.set(port, forKey: Key.port) } }
    var username: String { didSet { defaults.set(username, forKey: Key.username) } }
    var password: String { didSet { Keychain.setPassword(password) } }
    var allowAnonymous: Bool { didSet { defaults.set(allowAnonymous, forKey: Key.allowAnonymous) } }
    var readOnly: Bool { didSet { defaults.set(readOnly, forKey: Key.readOnly) } }
    var bonjourEnabled: Bool { didSet { defaults.set(bonjourEnabled, forKey: Key.bonjourEnabled) } }
    var keepScreenAwake: Bool { didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) } }
    var startOnLaunch: Bool { didSet { defaults.set(startOnLaunch, forKey: Key.startOnLaunch) } }

    static let portRange = 1024...65535

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.port: 2121,
            Key.username: "ftp",
            Key.allowAnonymous: false,
            Key.readOnly: false,
            Key.bonjourEnabled: true,
            Key.keepScreenAwake: true,
            Key.startOnLaunch: false,
        ])
        port = defaults.integer(forKey: Key.port)
        username = defaults.string(forKey: Key.username) ?? "ftp"
        allowAnonymous = defaults.bool(forKey: Key.allowAnonymous)
        readOnly = defaults.bool(forKey: Key.readOnly)
        bonjourEnabled = defaults.bool(forKey: Key.bonjourEnabled)
        keepScreenAwake = defaults.bool(forKey: Key.keepScreenAwake)
        startOnLaunch = defaults.bool(forKey: Key.startOnLaunch)

        if let stored = Keychain.password() {
            password = stored
        } else {
            password = Self.generatePassword()
            Keychain.setPassword(password)
        }
    }

    var isPortValid: Bool { Self.portRange.contains(port) }

    static func generatePassword() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}

enum Keychain {
    private static let service = "FTPServer"
    private static let account = "ftp-password"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func password() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String) {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
