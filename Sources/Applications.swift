import Foundation
import AppKit

struct InstalledApp: Identifiable, Sendable, Codable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let protected: Bool
    var isGoogleDrive: Bool {
        let identifier = bundleID.lowercased()
        return identifier == "com.google.drivefs" || identifier.hasPrefix("com.google.drivefs.") ||
            identifier == "com.google.googledrive" || name.lowercased() == "google drive"
    }
}

enum AppFileGroup: String, CaseIterable, Identifiable {
    case application = "程式本體", settings = "設定與視窗狀態", caches = "快取與日誌"
    case documents = "專用文件與帳號資料", review = "歸屬待確認"
    var id: String { rawValue }
}

struct AppFile: Identifiable, Sendable, Codable {
    var id: String { url.path }
    let url: URL
    let reason: String
    let review: Bool
    let identity: UInt64
    let modified: Date
    let tree: FileTreeSnapshot
    var bytes: Int64 { tree.bytes }
    var group: AppFileGroup {
        if review { return .review }
        if url.pathExtension == "app" { return .application }
        switch url.deletingLastPathComponent().lastPathComponent {
        case "Preferences", "Saved Application State": return .settings
        case "Caches", "Logs": return .caches
        default: return .documents
        }
    }
}

struct UninstallPlan: Sendable, Codable {
    let app: InstalledApp
    var files: [AppFile]
    var notes: [String]
    var inspectedApps: [InstalledApp] = []
}

struct AppCatalog: Sendable {
    let home: URL
    var roots: [URL] {
        if home.standardizedFileURL.path != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return [home.appendingPathComponent("Applications")]
        }
        return [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }
    func readApp(_ url: URL) -> InstalledApp? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard url.pathExtension.lowercased() == "app",
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true,
              let infoValues = try? infoURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              infoValues.isRegularFile == true, infoValues.isSymbolicLink != true,
              let size = infoValues.fileSize, size <= 4 * 1024 * 1024,
              let infoData = try? Data(contentsOf: infoURL),
              let info = (try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil)) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        // Read current metadata directly: Bundle may cache an earlier identity.
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let protected = url.path.hasPrefix("/System/") || id == Bundle.main.bundleIdentifier ||
            id == "com.apple.Safari" || id == "com.apple.finder" || id.hasPrefix("local.macsweep.")
        return InstalledApp(url: url.standardizedFileURL, name: name, bundleID: id,
                            version: info["CFBundleShortVersionString"] as? String ?? "—",
                            protected: protected)
    }
    func list() -> ([InstalledApp], [String]) {
        var apps: [InstalledApp] = []
        var notes: [String] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                    notes.append("\(url.path)：\(error.localizedDescription)"); return true
                }) else { continue }
            for case let url as URL in iterator {
                if let app = readApp(url) {
                    if !app.protected { apps.append(app) }
                    iterator.skipDescendants()
                }
            }
        }
        return (apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, notes)
    }
    func relatedPaths(_ app: InstalledApp) -> [(URL, String, Bool)] {
        // Drive data may include offline or unsynced documents. Do not offer it
        // through the uninstall flow, including ambiguous name-based matches.
        guard !app.isGoogleDrive else { return [] }
        let id = app.bundleID
        guard id.contains("."), !id.contains("/"), !id.contains(".."), !id.hasPrefix(".") else { return [] }
        var paths: [(URL, String, Bool)] = []
        func add(_ relative: String, _ reason: String, review: Bool = false) {
            paths.append((home.appendingPathComponent("Library/" + relative).standardizedFileURL, reason, review))
        }
        add("Preferences/\(id).plist", "App 識別碼完全相符 · 偏好設定")
        add("Caches/\(id)", "App 識別碼完全相符 · 快取")
        add("Logs/\(id)", "App 識別碼完全相符 · 日誌")
        add("Application Support/\(id)", "App 識別碼完全相符 · 專用資料與文件")
        add("Containers/\(id)", "App 識別碼完全相符 · 沙盒資料與文件")
        add("HTTPStorages/\(id)", "App 識別碼完全相符 · 網頁儲存資料")
        add("HTTPStorages/\(id).binarycookies", "App 識別碼完全相符 · Cookie")
        add("WebKit/\(id)", "App 識別碼完全相符 · WebKit 資料")
        add("Saved Application State/\(id).savedState", "App 識別碼完全相符 · 視窗狀態")
        if id == "com.google.Chrome" {
            add("Application Support/Google/Chrome", "Chrome 專用路徑；含個人設定檔、書籤、登入狀態與擴充套件，請確認是否保留", review: true)
            add("Caches/Google/Chrome", "Chrome 專用快取路徑；請先結束 Chrome，再確認移除", review: true)
        }
        let names = Set([app.name, app.url.deletingPathExtension().lastPathComponent])
        for name in names where name.count > 2 && !name.contains("/") && name != "." && name != ".." && name != id {
            add("Application Support/\(name)", "名稱相符；可能為共用資料，請先查看", review: true)
            add("Caches/\(name)", "名稱相符；需確認歸屬", review: true)
            add("Logs/\(name)", "名稱相符；需確認歸屬", review: true)
        }
        return paths
    }
    func snapshot(_ url: URL, reason: String, review: Bool) throws -> AppFile {
        let normalized = url.standardizedFileURL
        guard normalized.path == normalized.resolvingSymlinksInPath().path,
              (try normalized.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw CleanerError.unsafe("路徑包含符號連結，已略過。")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: normalized.path)
        guard let inode = attributes[.systemFileNumber] as? NSNumber,
              let date = attributes[.modificationDate] as? Date else {
            throw CleanerError.unsafe("無法確認項目身分。")
        }
        return AppFile(url: normalized, reason: reason, review: review, identity: inode.uint64Value, modified: date, tree: try FileTreeSnapshot.capture(normalized))
    }
    func sharedRelatedPaths(_ app: InstalledApp, installed: [InstalledApp]) -> Set<String> {
        let otherPaths = installed.filter { $0.id != app.id }.flatMap { relatedPaths($0).map { $0.0.path.lowercased() } }
        return Set(relatedPaths(app).compactMap { entry in
            let path = entry.0.path.lowercased()
            return otherPaths.contains { other in
                path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/")
            } ? entry.0.path : nil
        })
    }
    func plan(_ app: InstalledApp, installed: [InstalledApp]) -> UninstallPlan {
        var plan = UninstallPlan(app: app, files: [], notes: [
            "專用資料與沙盒可能含尚未備份的文件、帳號與資料庫，請先查看內容。",
            "共用 Group Containers、鑰匙圈、系統層級服務與其他帳號資料不會自動移除；有官方卸載程式的 App，應優先使用官方工具。",
            "桌面、文件及其他自選位置的作品無法僅靠 App 識別碼確認歸屬，不會自動搜尋刪除。"
        ])
        plan.inspectedApps = installed
        guard !app.protected else { plan.notes.insert("此 App 屬於系統保護項目或 MacSweep 本身，不能在此卸載。", at: 0); return plan }
        if app.isGoogleDrive {
            plan.notes.insert("Google Drive 僅提供移除程式本體；同步、離線內容與關聯資料不列入清單。", at: 0)
        }
        do { plan.files.append(try snapshot(app.url, reason: "程式本體", review: false)) }
        catch { plan.notes.insert("程式本體無法檢查：\(error.localizedDescription)", at: 0); return plan }
        if installed.contains(where: { $0.bundleID == app.bundleID && $0.id != app.id }) {
            plan.notes.insert("偵測到相同 App 的另一份安裝，為保留其資料，此次只提供移除程式本體。", at: 0)
            return plan
        }
        let shared = sharedRelatedPaths(app, installed: installed)
        for (url, reason, review) in relatedPaths(app) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard !shared.contains(url.path) else {
                plan.notes.append("\(url.path)：與其他已安裝 App 的關聯路徑重疊，已保留。")
                continue
            }
            do { plan.files.append(try snapshot(url, reason: reason, review: review)) }
            catch { plan.notes.append("\(url.path)：\(error.localizedDescription)") }
        }
        return plan
    }
    func uninstall(_ plan: UninstallPlan, selected: Set<String>,
                   moveToTrash: (URL, inout NSURL?) throws -> Void = { url, destination in
                       try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                   }) -> ([String], [String]) {
        let app = plan.app
        let plannedIDs = Set(plan.files.map(\.id))
        guard plannedIDs.count == plan.files.count, plannedIDs.contains(app.id), selected.isSubset(of: plannedIDs) else {
            return ([], ["卸載明細缺少程式本體、包含重複項目，或選取項目已失效。未移動任何資料，請重新檢查。"])
        }
        guard !app.protected, selected.contains(app.id), let current = readApp(app.url),
              current.bundleID == app.bundleID, !current.protected else {
            return ([], ["程式已變更、受保護，或未選取程式本體。請重新檢查。"])
        }
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == app.bundleID }) else {
            return ([], ["請先完全結束 \(app.name) 及其背景程序，再執行卸載。"])
        }
        if selected.contains(where: { $0 != app.id }) {
            var (currentApps, notes) = list()
            // Retain manually added locations across the inspection worker boundary.
            // An unavailable drive or changed identity makes ownership uncertain.
            for known in plan.inspectedApps where known.id != app.id {
                guard let fresh = readApp(known.url), fresh.bundleID == known.bundleID,
                      fresh.name == known.name else {
                    return ([], ["先前檢查的 App 已變更或無法讀取：\(known.url.path)。無法確認關聯資料歸屬，未移動任何項目；請重新整理後再檢查。"])
                }
                if !currentApps.contains(where: { $0.id == fresh.id }) { currentApps.append(fresh) }
            }
            guard notes.isEmpty else { return ([], ["無法完整重新檢查安裝清單，未移動任何項目。請重新整理後再試。"] + notes) }
            guard !currentApps.contains(where: { $0.bundleID == app.bundleID && $0.id != app.id }) else {
                return ([], ["偵測到另一份相同 App，關聯資料可能仍被使用；未移動任何項目。請重新整理卸載明細。"])
            }
            guard sharedRelatedPaths(app, installed: currentApps).isDisjoint(with: selected) else {
                return ([], ["所選資料與其他已安裝 App 的關聯路徑重疊；未移動任何項目，請重新檢查。"])
            }
        }
        let allowed = Set(relatedPaths(app).map { $0.0.path }).union([app.id])
        let targets = plan.files.filter { selected.contains($0.id) }
        do {
            // Validate every selected item before moving anything.
            for file in targets {
                guard allowed.contains(file.id) else { throw CleanerError.unsafe("項目不在此 App 的允許清單中。") }
                let fresh = try snapshot(file.url, reason: file.reason, review: file.review)
                guard fresh.identity == file.identity, fresh.modified == file.modified, fresh.tree == file.tree else { throw CleanerError.changed }
            }
        } catch { return ([], ["未移動任何項目：\(error.localizedDescription)"]) }
        var removed: [String] = []
        var errors: [String] = []
        // Move the bundle first: if permission blocks it, preserve all user data.
        for file in targets.sorted(by: {
            if $0.id == app.id { return $1.id != app.id }
            if $1.id == app.id { return false }
            return $0.id < $1.id
        }) {
            do {
                let fresh = try snapshot(file.url, reason: file.reason, review: file.review)
                guard fresh.identity == file.identity, fresh.modified == file.modified, fresh.tree == file.tree else { throw CleanerError.changed }
                var destination: NSURL?
                try moveToTrash(file.url, &destination)
                removed.append(file.id)
                #if UI_TEST
                let receiptURL = home.appendingPathComponent("app-trash-receipt.txt")
                let previous = (try? String(contentsOf: receiptURL, encoding: .utf8)) ?? ""
                let exists = destination.map { FileManager.default.fileExists(atPath: $0.path ?? "") } ?? false
                let receipt = previous + "\(file.id) -> \(destination?.path ?? "unknown"); trash exists: \(exists); original exists: \(FileManager.default.fileExists(atPath: file.id))\n"
                try receipt.write(to: receiptURL, atomically: true, encoding: .utf8)
                #endif
            } catch {
                errors.append("\(file.url.path)：\(error.localizedDescription)")
                break
            }
        }
        return (removed, errors)
    }
}
