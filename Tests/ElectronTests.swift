import Foundation

@main
struct ElectronTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("Electron-test-\(UUID().uuidString)").standardizedFileURL
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let cleaner = Cleaner(home: home)
        func write(_ path: String, _ data: Data = Data("fixture".utf8)) throws -> URL {
            let url = home.appendingPathComponent(path).standardizedFileURL
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        func app(_ name: String, id: String, electron: Bool) throws {
            let info = ["CFBundleName": name, "CFBundleIdentifier": id, "CFBundleVersion": "1"]
            _ = try write("Applications/\(name).app/Contents/Info.plist", PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
            if electron { _ = try write("Applications/\(name).app/Contents/Frameworks/Electron Framework.framework/marker") }
        }
        func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS: \(message)") }
        try app("ElectronFixture", id: "org.fixture.electron", electron: true)
        try app("NativeFixture", id: "org.fixture.native", electron: false)
        try app("Google Drive", id: "com.google.drivefs", electron: true)
        let cache = try write("Library/Application Support/ElectronFixture/Cache/data")
        _ = try write("Library/Application Support/ElectronFixture/Code Cache/data")
        _ = try write("Library/Application Support/ElectronFixture/Local Storage/database")
        _ = try write("Library/Application Support/ElectronFixture/pending-uploads/document")
        _ = try write("Library/Application Support/NativeFixture/Cache/data")
        _ = try write("Library/Application Support/Google Drive/Cache/document")
        let result = try cleaner.scan(includeSupport: false, deep: true)
        let caches = result.candidates.filter { $0.category == .electronCaches }
        check(caches.count == 2, "Installed Electron cache and code cache discovered without native or Drive data")
        check(caches.allSatisfy { ["Cache", "Code Cache"].contains($0.url.lastPathComponent) }, "Electron account state and pending uploads excluded")
        check(caches.contains { $0.url.path == cache.deletingLastPathComponent().path }, "Electron support directory matched to installed App")
        let dataRoot = cache.deletingLastPathComponent().deletingLastPathComponent()
        do { try cleaner.validate(dataRoot, category: .electronCaches); fatalError("Parent accepted") }
        catch { print("PASS: Whole Electron support folder rejected before deletion") }
        do { try cleaner.validate(dataRoot.appendingPathComponent("Local Storage"), category: .electronCaches); fatalError("Local Storage accepted") }
        catch { print("PASS: Electron Local Storage rejected before deletion") }
        let gpu = dataRoot.appendingPathComponent("GPUCache")
        try fm.createSymbolicLink(at: gpu, withDestinationURL: cache.deletingLastPathComponent())
        do { try cleaner.validate(gpu, category: .electronCaches); fatalError("Link accepted") }
        catch { print("PASS: Electron cache symlink rejected") }
        try fm.removeItem(at: home.appendingPathComponent("Applications/ElectronFixture.app"))
        do { try cleaner.validate(cache.deletingLastPathComponent(), category: .electronCaches); fatalError("Missing App accepted") }
        catch { print("PASS: Removed App invalidates Electron cache rule at deletion time") }
    }
}
