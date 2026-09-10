import Foundation

@main
struct MetadataTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("MacSweep-metadata-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let cleaner = Cleaner(home: home)
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); print("PASS: \(label)")
        }
        func file(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            return url
        }
        func backup(_ name: String, id: String?, date: Date, completed: Bool) throws -> URL {
            let url = cleaner.root(.backups).appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            var info: [String: Any] = ["Device Name": "測試手機", "Last Backup Date": date]
            if let id { info["Target Identifier"] = id }
            let status: [String: Any] = ["Date": date, "SnapshotState": completed ? "finished" : "uploading"]
            for (name, plist) in [("Info.plist", info), ("Status.plist", status)] {
                try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url.appendingPathComponent(name))
            }
            return url
        }
        let old = try backup("old", id: "device-A", date: Date(timeIntervalSince1970: 100), completed: true)
        let latest = try backup("latest", id: "device-A", date: Date(timeIntervalSince1970: 200), completed: true)
        let incomplete = try backup("incomplete", id: "device-A", date: Date(timeIntervalSince1970: 300), completed: false)
        let unknown = try backup("unknown", id: nil, date: Date(), completed: true)
        let other = try backup("other", id: "device-B", date: Date(timeIntervalSince1970: 50), completed: true)
        let chrome = try file("Library/Application Support/Google/Chrome/Default/Cache/data")
        _ = try file("Library/Application Support/Google/Chrome/Default/Cookies")
        _ = try file("Library/Application Support/Google/Chrome/Default/Local Storage/data")
        let drive = try file("Library/Application Support/Google/DriveFS/account/content_cache/data")
        _ = try file("Library/Caches/Google/DriveFS/data")
        let disk = try file("Library/Caches/Google/Chrome/Default/data")
        let result = try cleaner.scan(includeSupport: true, deep: true)
        func item(_ url: URL) -> Candidate { result.candidates.first { $0.url.path == url.path }! }
        check(item(latest).backup?.isLatest == true && item(old).backup?.isLatest == false, "Newest completed backup selected by metadata date, not folder name")
        check(item(incomplete).backup?.isLatest == false, "Incomplete newer backup does not displace completed backup")
        check(item(unknown).backup?.isLatest == false, "Unknown device identity cannot create a latest-backup claim")
        check(item(other).backup?.isLatest == true, "Devices sharing a display name stay in separate groups")
        check(item(latest).name == "測試手機", "Device name appears in candidate")
        check(result.candidates.contains { $0.url.path == chrome.deletingLastPathComponent().path && $0.category == .chromeProfiles }, "Chrome generated profile cache discovered")
        check(!result.candidates.contains { $0.url.lastPathComponent == "Cookies" || $0.url.lastPathComponent == "Local Storage" }, "Chrome cookies and local storage excluded")
        check(!result.candidates.contains { drive.path.hasPrefix($0.id + "/") || $0.id.contains("DriveFS") }, "Drive content and its parent directories excluded even with App data enabled")
        check(result.candidates.contains { $0.url.path == disk.deletingLastPathComponent().path }, "Chrome disk cache remains available after excluding Google parent")
        do { try cleaner.validate(cleaner.root(.support).appendingPathComponent("Google"), category: .support); fatalError("Unsafe parent accepted") }
        catch { print("PASS: Delete-time validation rejects Google parent") }
        let escaped = cleaner.root(.chromeProfiles).appendingPathComponent("Default/Local Storage")
        do { try cleaner.validate(escaped, category: .chromeProfiles); fatalError("Unsafe profile data accepted") }
        catch { print("PASS: Delete-time validation rejects non-cache profile folders") }
        let linked = cleaner.root(.chromeProfiles).appendingPathComponent("Profile 9")
        try fm.createSymbolicLink(at: linked, withDestinationURL: chrome.deletingLastPathComponent().deletingLastPathComponent())
        do { try cleaner.validate(linked.appendingPathComponent("Cache"), category: .chromeProfiles); fatalError("Symlink accepted") }
        catch { print("PASS: Chrome profile symlink rejected") }
        let encoded = try JSONEncoder().encode(result.candidates)
        let decoded = try JSONDecoder().decode([Candidate].self, from: encoded)
        check(decoded.first { $0.url.path == latest.path }?.backup?.isLatest == true, "Backup metadata survives scanner worker protocol")
        try Data("invalid".utf8).write(to: latest.appendingPathComponent("Info.plist"))
        check(BackupMetadata.read(at: latest).deviceID == nil, "Malformed metadata remains unidentified")
        try fm.removeItem(at: latest.appendingPathComponent("Info.plist"))
        try fm.createSymbolicLink(at: latest.appendingPathComponent("Info.plist"), withDestinationURL: old.appendingPathComponent("Info.plist"))
        check(BackupMetadata.read(at: latest).deviceID == nil, "Metadata parser does not follow external symlinks")
    }
}
