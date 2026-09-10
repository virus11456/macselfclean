import Foundation
import AppKit

struct Leftover: Identifiable, Sendable, Codable {
    var id: String { file.id }
    let bundleID: String
    let file: AppFile
}

extension AppCatalog {
    func leftoverID(_ url: URL) -> String? {
        let url = url.standardizedFileURL
        let base = home.appendingPathComponent("Library").standardizedFileURL
        let parent = url.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().path == base.path,
              ["Preferences", "Caches", "Logs"].contains(parent.lastPathComponent) else { return nil }
        var id = url.lastPathComponent
        if parent.lastPathComponent == "Preferences" {
            guard url.pathExtension == "plist" else { return nil }
            id = url.deletingPathExtension().lastPathComponent
        }
        guard id.range(of: "^[A-Za-z][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+){2,}$", options: .regularExpression) != nil,
              !["com.apple.", "systemgroup.", "group.", "local.macsweep.", "com.google.drive", "com.google.googledrive"].contains(where: { id.lowercased().hasPrefix($0) }) else { return nil }
        return id
    }

    func hasInstalledOwner(_ id: String, apps: [InstalledApp]) -> Bool {
        let target = id.lowercased()
        if apps.contains(where: {
            let owner = $0.bundleID.lowercased()
            let sameVendor = owner.split(separator: ".").prefix(2).joined(separator: ".") == target.split(separator: ".").prefix(2).joined(separator: ".")
            return sameVendor || owner == target || target.hasPrefix(owner + ".") || owner.hasPrefix(target + ".")
        }) { return true }
        if home.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
        return false
    }

    func leftovers(additionalApps: [InstalledApp] = []) -> ([Leftover], [String]) {
        let (installed, failures) = list()
        guard failures.isEmpty else { return ([], failures + ["安裝清單未完整讀取，暫不判斷殘留。"] ) }
        var items: [Leftover] = [], notes: [String] = []
        let fm = FileManager.default
        for folder in ["Preferences", "Caches", "Logs"] {
            let root = home.appendingPathComponent("Library/" + folder)
            guard fm.fileExists(atPath: root.path) else { continue }
            do {
                for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    guard let id = leftoverID(url), !hasInstalledOwner(id, apps: installed + additionalApps) else { continue }
                    do {
                        let file = try snapshot(url, reason: "未找到相符的已安裝 App；可能仍屬於背景工具或未登記的 App", review: true)
                        items.append(Leftover(bundleID: id, file: file))
                    } catch { notes.append("\(url.path)：\(error.localizedDescription)") }
                }
            } catch { notes.append("\(root.path)：\(error.localizedDescription)") }
        }
        return (items.sorted { $0.id < $1.id }, notes)
    }
}

struct LeftoversRequest: Codable {
    let home: URL
    let installed: [InstalledApp]
}
struct LeftoversResult: Codable {
    let items: [Leftover]
    let notes: [String]
}
func leftoversWorkerMain(_ directory: String) {
    let root = URL(fileURLWithPath: directory)
    do {
        let request = try JSONDecoder().decode(LeftoversRequest.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
        let (items, notes) = AppCatalog(home: request.home).leftovers(additionalApps: request.installed)
        try JSONEncoder().encode(LeftoversResult(items: items, notes: notes)).write(to: root.appendingPathComponent("result.json"), options: .atomic)
    } catch { exit(1) }
}
