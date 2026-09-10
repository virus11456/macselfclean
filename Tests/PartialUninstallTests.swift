import Foundation

@main
struct PartialUninstallTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("PartialTests-\(UUID().uuidString)").standardizedFileURL
        defer { try? fm.removeItem(at: home) }
        func write(_ path: String, _ data: Data) throws -> URL {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        _ = try write("Applications/Fixture.app/Contents/Info.plist", PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.partial.fixture", "CFBundleName": "Fixture"], format: .xml, options: 0))
        let cache = try write("Library/Caches/org.partial.fixture/data", Data("cache".utf8))
        let prefs = try write("Library/Preferences/org.partial.fixture.plist", Data("settings".utf8))
        let catalog = AppCatalog(home: home)
        let app = catalog.readApp(home.appendingPathComponent("Applications/Fixture.app"))!
        let plan = catalog.plan(app, installed: [app])
        let selected = Set(plan.files.map(\.id))
        precondition(selected.count == 3)
        var calls = [String]()
        let denied = catalog.uninstall(plan, selected: selected) { url, _ in
            calls.append(url.path)
            throw CocoaError(.fileWriteNoPermission)
        }
        precondition(calls == [app.id] && denied.0.isEmpty && denied.1.count == 1 && fm.fileExists(atPath: prefs.path))
        print("PASS: Bundle move failure stops before any related data move")
        calls = []
        let destination = home.appendingPathComponent("SimulatedTrash/Fixture.app")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = catalog.uninstall(plan, selected: selected) { url, receipt in
            calls.append(url.path)
            if url.path == app.id {
                try fm.moveItem(at: url, to: destination)
                receipt = destination as NSURL
            } else { throw CocoaError(.fileWriteNoPermission) }
        }
        precondition(calls.count == 2 && calls.first == app.id && partial.0 == [app.id] && partial.1.count == 1)
        print("PASS: First related data move failure stops all subsequent moves")
        precondition(fm.fileExists(atPath: destination.path) && fm.fileExists(atPath: cache.path) && fm.fileExists(atPath: prefs.path))
        precondition(selected.subtracting(partial.0).count == 2)
        print("PASS: Partial result reports moved bundle separately from retained data")
        try fm.moveItem(at: destination, to: app.url)
        let fresh = catalog.plan(app, installed: [app])
        calls = []
        let success = catalog.uninstall(fresh, selected: Set(fresh.files.map(\.id))) { url, receipt in
            calls.append(url.path)
            let target = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try fm.moveItem(at: url, to: target)
            receipt = target as NSURL
        }
        precondition(success.0.count == 3 && success.1.isEmpty && calls.first == app.id)
        print("PASS: Successful fixture moves still process all selected items bundle first")
    }
}
