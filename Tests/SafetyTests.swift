import Foundation

@main
struct SafetyTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("MacSweep-test-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let cleaner = Cleaner(home: home)
        let now = Date()
        func fixture(_ category: Category, _ name: String, days: Double) throws -> URL {
            let folder = cleaner.root(category).appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("data.txt")
            try Data("test data".utf8).write(to: file)
            let date = now.addingTimeInterval(-days * 86400)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
            return folder
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            print("PASS: \(message)")
        }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body(); fatalError("Expected rejection: \(label)") }
            catch { print("PASS: \(label)") }
        }
        let old = try fixture(.cache, "old-cache", days: 10)
        _ = try fixture(.cache, "recent-cache", days: 1)
        _ = try fixture(.logs, "old-logs", days: 40)
        _ = try fixture(.logs, "recent-logs", days: 20)
        _ = try fixture(.support, "important-app-data", days: 400)
        let active = try fixture(.cache, "old-folder-active-child", days: 15)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: active.appendingPathComponent("data.txt").path)
        var result = try cleaner.scan(includeSupport: false, now: now)
        check(Set(result.candidates.map(\.name)) == Set(["old-cache", "old-logs"]), "Age rules include descendant modification times")
        check(result.candidates.allSatisfy { $0.category != .support }, "App data excluded by default")
        result = try cleaner.scan(includeSupport: true, now: now)
        check(result.candidates.contains { $0.category == .support }, "App data requires explicit scan option")
        try rejectsOutside(cleaner: cleaner, home: home, rejects: rejects)
        let linked = cleaner.root(.cache).appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: old)
        rejects("Symlink candidate rejected") { try cleaner.validate(linked, category: .cache) }
        let nested = try fixture(.cache, "nested-link", days: 20)
        try fm.createSymbolicLink(at: nested.appendingPathComponent("link"), withDestinationURL: old)
        rejects("Nested symlink rejects entire candidate") { _ = try cleaner.inventory(nested) }
        result = try cleaner.scan(includeSupport: false, now: now, deep: true)
        check(!result.candidates.contains { $0.name == "nested-link" || $0.name == "linked" }, "Linked data never offered for cleanup")
        check(result.notes.count == 2, "Skipped links are reported")
        let candidate = result.candidates.first { $0.url.path == old.path }!
        try Data("changed after scan".utf8).write(to: old.appendingPathComponent("data.txt"))
        rejects("Changed item rejected before trash operation") { try cleaner.trash(candidate) }
        check(fm.fileExists(atPath: old.path), "Changed item remains in place")
        try fm.removeItem(at: cleaner.root(.logs))
        try fm.createSymbolicLink(at: cleaner.root(.logs), withDestinationURL: cleaner.root(.support))
        result = try cleaner.scan(includeSupport: false, now: now)
        check(!result.candidates.contains { $0.category == .logs }, "Redirected root skipped")
        _ = try fixture(.backups, "device-backup", days: 1)
        let deep = try cleaner.scan(includeSupport: false, now: now, deep: true)
        check(deep.candidates.contains { $0.name == "recent-cache" && $0.minimumAge == 0 }, "Deep scan includes recent caches explicitly")
        check(deep.candidates.contains { $0.category == .backups }, "Deep scan discovers device backups")
        let conservative = try cleaner.scan(includeSupport: false, now: now)
        check(!conservative.candidates.contains { $0.category == .backups }, "Conservative scan excludes backups")
        _ = try fixture(.installers, "installer.dmg", days: 1)
        _ = try fixture(.installers, "personal-document.pdf", days: 1)
        _ = try fixture(.iphoneFirmware, "iPhone.ipsw", days: 1)
        let installers = try cleaner.scan(includeSupport: false, deep: true)
        check(installers.candidates.contains { $0.name == "installer.dmg" }, "Download installer is included")
        check(installers.candidates.contains { $0.category == .iphoneFirmware }, "iPhone firmware is included")
        check(!installers.candidates.contains { $0.name == "personal-document.pdf" }, "Ordinary downloaded documents excluded")
        let protectedUpdate = Candidate(url: home.appendingPathComponent("fake-update"), category: .macUpdates, inventory: Inventory())
        rejects("System-managed updates cannot be trashed") { _ = try cleaner.trash(protectedUpdate) }
        _ = try fixture(.claudeCaches, "Cache", days: 1)
        _ = try fixture(.claudeCaches, "pending-uploads", days: 1)
        let appCaches = try cleaner.scan(includeSupport: false, deep: true)
        check(appCaches.candidates.contains { $0.category == .claudeCaches && $0.name == "Cache" }, "Claude generated cache is included")
        check(!appCaches.candidates.contains { $0.name == "pending-uploads" }, "Claude pending uploads and personal state excluded")
        let parent = Candidate(url: home.appendingPathComponent("parent"), category: .cache, inventory: Inventory(bytes: 20))
        let child = Candidate(url: home.appendingPathComponent("parent/child"), category: .chatgptNativeCaches, inventory: Inventory(bytes: 10))
        check(uniqueCandidates([parent, child]).count == 1, "Nested cache rules do not double count or offer duplicate deletion")
        for name in ["CloudKit", "iCloud", "com.backup42.desktop", "com.pogoplug.Backup", "com.dropbox.mbd.external.fixture", "Metadata"] {
            let protectedCache = try fixture(.cache, name, days: 90)
            rejects("Sync, backup or aggregate cache rejected: \(name)") { try cleaner.validate(protectedCache, category: .cache) }
        }
        let protectedScan = try cleaner.scan(includeSupport: false, deep: true)
        check(!protectedScan.candidates.contains { ["CloudKit", "iCloud", "com.backup42.desktop", "com.pogoplug.Backup", "com.dropbox.mbd.external.fixture", "Metadata"].contains($0.name) }, "Protected sync and backup state omitted from deep-scan results")
        let cancellation = ScanCancellation()
        cancellation.cancel()
        rejects("Cancelled scan exits without results") {
            _ = try cleaner.scan(includeSupport: false, cancellation: cancellation)
        }
        print("All safety tests passed. No user data was scanned or trashed.")
    }

    static func rejectsOutside(cleaner: Cleaner, home: URL,
                              rejects: (String, () throws -> Void) -> Void) throws {
        rejects("Root folder cannot be removed") { try cleaner.validate(cleaner.root(.cache), category: .cache) }
        rejects("Outside path rejected") { try cleaner.validate(home.appendingPathComponent("Documents"), category: .cache) }
        rejects("Nested path rejected") {
            try cleaner.validate(cleaner.root(.cache).appendingPathComponent("old-cache/data.txt"), category: .cache)
        }
    }
}
