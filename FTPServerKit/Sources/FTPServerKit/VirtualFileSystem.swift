import Foundation

struct VirtualFileSystem {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let size: UInt64
        let modified: Date
    }

    struct ResolvedPath {
        let path: String
        let url: URL
        var isRoot: Bool { path == "/" }
        var name: String { (path as NSString).lastPathComponent }
    }

    let root: URL
    private let resolvedRootPath: String
    private(set) var currentDirectory = "/"

    init(root: URL) {
        self.root = root.standardizedFileURL
        self.resolvedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func resolve(_ input: String) -> ResolvedPath? {
        guard !input.contains("\0") else { return nil }
        var components = input.hasPrefix("/") ? [] : currentDirectory.split(separator: "/").map(String.init)
        for part in input.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(part))
            }
        }
        let url = components.reduce(root) { $0.appendingPathComponent($1) }
        if FileManager.default.fileExists(atPath: url.path) {
            let real = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard real == resolvedRootPath || real.hasPrefix(resolvedRootPath + "/") else { return nil }
        }
        return ResolvedPath(path: "/" + components.joined(separator: "/"), url: url)
    }

    mutating func changeDirectory(to input: String) -> Bool {
        guard let target = resolve(input), isDirectory(target.url) else { return false }
        currentDirectory = target.path
        return true
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func entry(at url: URL) -> Entry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        return Entry(
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        )
    }

    func contents(of url: URL) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { entry(at: url.appendingPathComponent($0)) }
    }
}

enum ListingFormatter {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func unixLine(for entry: VirtualFileSystem.Entry, now: Date = Date()) -> String {
        let mode = entry.isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
        let size = String(entry.isDirectory ? 4096 : entry.size)
        return "\(mode)    1 ftp      ftp      \(pad(size, 12)) \(unixDate(entry.modified, now: now)) \(entry.name)"
    }

    static func machineFacts(for entry: VirtualFileSystem.Entry, readOnly: Bool, name: String? = nil) -> String {
        let perms: String
        if entry.isDirectory {
            perms = readOnly ? "el" : "cdeflmp"
        } else {
            perms = readOnly ? "r" : "adfrw"
        }
        var facts = "type=\(entry.isDirectory ? "dir" : "file");"
        if !entry.isDirectory { facts += "size=\(entry.size);" }
        facts += "modify=\(timestamp(entry.modified));perm=\(perms);"
        return facts + " " + (name ?? entry.name)
    }

    static func timestamp(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func parseTimestamp(_ string: String) -> Date? {
        let digits = string.split(separator: ".").first.map(String.init) ?? ""
        guard digits.count == 14, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        func field(_ offset: Int, _ length: Int) -> Int {
            let start = digits.index(digits.startIndex, offsetBy: offset)
            return Int(digits[start..<digits.index(start, offsetBy: length)])!
        }
        let components = DateComponents(
            year: field(0, 4), month: field(4, 2), day: field(6, 2),
            hour: field(8, 2), minute: field(10, 2), second: field(12, 2)
        )
        return utcCalendar.date(from: components)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func unixDate(_ date: Date, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let month = months[c.month! - 1]
        let day = pad(String(c.day!), 2)
        if abs(now.timeIntervalSince(date)) < 180 * 24 * 3600 {
            return "\(month) \(day) " + String(format: "%02d:%02d", c.hour!, c.minute!)
        }
        return "\(month) \(day)  \(c.year!)"
    }

    private static func pad(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : String(repeating: " ", count: width - string.count) + string
    }
}
