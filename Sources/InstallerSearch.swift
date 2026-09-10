import Foundation

extension Cleaner {
    func installerPathAllowed(_ item: URL) -> Bool {
        let base = root(.installers)
        guard item.path.hasPrefix(base.path + "/"), Category.installers.accepts(item) else { return false }
        let relative = item.path.dropFirst(base.path.count + 1).split(separator: "/")
        guard (1...3).contains(relative.count), !item.lastPathComponent.hasPrefix(".") else { return false }
        var parent = item.deletingLastPathComponent()
        while parent.path != base.path {
            guard ordinaryDownloadFolder(parent) else { return false }
            parent = parent.deletingLastPathComponent()
        }
        return true
    }

    private func ordinaryDownloadFolder(_ url: URL) -> Bool {
        guard !url.lastPathComponent.hasPrefix("."), url.pathExtension.isEmpty,
              !["google drive", "drivefs", "cloudstorage"].contains(url.lastPathComponent.lowercased()),
              url.resolvingSymlinksInPath().path == url.path,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
              values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { return false }
        return true
    }

    func downloadInstallers(cancellation: ScanCancellation?, skip: Set<String>, event: (ScanEvent) -> Void) throws -> ([URL], [String]) {
        var queue: [(URL, Int)] = [(root(.installers), 0)]
        var found: [URL] = [], notes: [String] = []
        var checked = 0
        while !queue.isEmpty {
            let (folder, depth) = queue.removeLast()
            try cancellation?.check()
            try Task.checkCancellation()
            if skip.contains(folder.path) { continue }
            event(ScanEvent(kind: "checking", path: folder.path))
            defer { event(ScanEvent(kind: "checked", path: folder.path)) }
            do {
                for entry in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    try cancellation?.check()
                    try Task.checkCancellation()
                    checked += 1
                    if checked > 5000 {
                        notes.append("下載安裝檔：已達 5,000 個目錄項目上限，部分子資料夾未完成檢查。")
                        return (found, notes)
                    }
                    let item = entry.standardizedFileURL
                    if skip.contains(item.path) { continue }
                    if Category.installers.accepts(item) && installerPathAllowed(item) { found.append(item) }
                    else if depth < 2 && ordinaryDownloadFolder(item) { queue.append((item, depth + 1)) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { notes.append("\(folder.path)：\(error.localizedDescription)") }
        }
        return (found, notes)
    }
}
