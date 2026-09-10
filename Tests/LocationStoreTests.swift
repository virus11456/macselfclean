import Foundation

@main
struct LocationStoreTests {
    static func main() throws {
        let suite = "MacSweep.LocationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppLocationStore(defaults: defaults)
        let initial = try store.load()
        precondition(initial.isEmpty)
        let app = InstalledApp(url: URL(fileURLWithPath: "/Volumes/Offline/Example.app"), name: "Example", bundleID: "org.example.fixture", version: "1", protected: false)
        try store.save([app, app])
        let reopened = AppLocationStore(defaults: UserDefaults(suiteName: suite)!)
        let loaded = try reopened.load()
        precondition(loaded.count == 1 && loaded.first?.id == app.id && loaded.first?.bundleID == app.bundleID)
        print("PASS: Saved external locations survive store recreation and deduplicate")
        precondition(!FileManager.default.fileExists(atPath: app.id) && loaded.count == 1)
        print("PASS: Unavailable location remains recorded without requiring mounted disk")
        try store.save([])
        let cleared = try reopened.load()
        precondition(cleared.isEmpty)
        print("PASS: Forgetting locations clears records without filesystem deletion")
        defaults.set(Data("invalid".utf8), forKey: store.key)
        do { _ = try store.load(); fatalError("Corrupt records ignored") }
        catch { print("PASS: Corrupt location records produce an error instead of empty success") }
    }
}
