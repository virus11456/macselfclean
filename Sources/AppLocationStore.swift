import Foundation

struct AppLocationStore {
    let defaults: UserDefaults
    var key = "MacSweep.savedAppLocations.v1"

    func load() throws -> [InstalledApp] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([InstalledApp].self, from: data)
    }
    func save(_ apps: [InstalledApp]) throws {
        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.id).inserted }
        defaults.set(try JSONEncoder().encode(unique), forKey: key)
    }
}
