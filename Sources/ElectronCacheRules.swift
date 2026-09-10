import Foundation

extension Cleaner {
    /// Discover only standard generated-cache children for installed Electron apps.
    /// Application Support itself, account state, uploads and cloud sync never qualify.
    func electronCacheURLs() -> [URL] {
        let fm = FileManager.default
        let base = root(.electronCaches)
        guard base.resolvingSymlinksInPath().path == base.path,
              let folders = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        let (apps, failures) = AppCatalog(home: home).list()
        guard failures.isEmpty else { return [] }
        var names = Set<String>()
        for app in apps where !app.protected && !app.isGoogleDrive {
            let framework = app.url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
            guard framework.standardizedFileURL.resolvingSymlinksInPath().path == framework.standardizedFileURL.path,
                  (try? framework.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let bundleName = Bundle(url: app.url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            for name in [app.name, bundleName, app.url.deletingPathExtension().lastPathComponent].compactMap({ $0 }) {
                guard name.count > 2, !name.contains("/"), !name.contains(".."),
                      !["google", "google drive", "drivefs", "mobilesync", "cloudstorage"].contains(name.lowercased()) else { continue }
                names.insert(name.lowercased())
            }
        }
        return folders.filter { names.contains($0.lastPathComponent.lowercased()) }.flatMap { folder in
            Self.chromeCacheNames.map { folder.appendingPathComponent($0).standardizedFileURL }
                .filter { fm.fileExists(atPath: $0.path) }
        }
    }
}
