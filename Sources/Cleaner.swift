import Foundation

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

enum Category: String, CaseIterable, Identifiable, Sendable, Codable {
    case cache = "快取", logs = "日誌", support = "App 資料（手動檢查）"
    case developer = "Xcode 建置暫存", archives = "Xcode 封存", backups = "iPhone／iPad 備份"
    case installers = "下載的安裝檔", iphoneFirmware = "iPhone 更新檔", ipadFirmware = "iPad 更新檔"
    case macInstallers = "macOS 安裝程式", macUpdates = "macOS 系統更新（唯讀）"
    case claudeCaches = "Claude 應用程式快取", chromeCaches = "Chrome 輔助快取"
    case safariCaches = "Safari 沙盒快取", chatgptCaches = "ChatGPT 沙盒快取", driveLogs = "Google Drive 日誌"
    case chatgptNativeCaches = "ChatGPT／Codex 檔案快取"
    case chromeProfiles = "Chrome 個人檔案快取"
    case chromeDisk = "Chrome 磁碟快取"
    case electronCaches = "Electron App 快取"
    var id: String { rawValue }
    var relativePath: String {
        switch self {
        case .cache: return "Library/Caches"
        case .logs: return "Library/Logs"
        case .support, .electronCaches: return "Library/Application Support"
        case .developer: return "Library/Developer/Xcode/DerivedData"
        case .archives: return "Library/Developer/Xcode/Archives"
        case .backups: return "Library/Application Support/MobileSync/Backup"
        case .installers: return "Downloads"
        case .iphoneFirmware: return "Library/iTunes/iPhone Software Updates"
        case .ipadFirmware: return "Library/iTunes/iPad Software Updates"
        case .macInstallers: return "Applications"
        case .macUpdates: return "Library/Updates"
        case .claudeCaches: return "Library/Application Support/Claude"
        case .chromeCaches: return "Library/Application Support/Google/Chrome"
        case .chromeProfiles: return "Library/Application Support/Google/Chrome"
        case .chromeDisk: return "Library/Caches/Google/Chrome"
        case .safariCaches: return "Library/Containers/com.apple.Safari/Data/Library/Caches"
        case .chatgptCaches: return "Library/Containers/com.openai.chat/Data/Library/Caches"
        case .driveLogs: return "Library/Application Support/Google/DriveFS/Logs"
        case .chatgptNativeCaches: return "Library/Caches/com.openai.codex"
        }
    }
    var age: TimeInterval {
        switch self {
        case .cache: return 7 * 86400
        case .logs: return 30 * 86400
        default: return 0
        }
    }
    var readOnly: Bool { self == .macUpdates }
    var isInstaller: Bool { [.installers, .iphoneFirmware, .ipadFirmware, .macInstallers, .macUpdates].contains(self) }
    var isCache: Bool { [.cache, .claudeCaches, .chromeCaches, .chromeProfiles, .chromeDisk, .electronCaches, .safariCaches, .chatgptCaches, .chatgptNativeCaches].contains(self) }
    func accepts(_ url: URL) -> Bool {
        if self == .chromeDisk { return Cleaner.isChromeProfile(url.lastPathComponent) }
        if self == .chatgptNativeCaches { return url.lastPathComponent == "fsCachedData" }
        if self == .claudeCaches {
            return ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"].contains(url.lastPathComponent)
        }
        if self == .chromeCaches {
            return ["GPUPersistentCache", "GraphiteDawnCache", "component_crx_cache", "extensions_crx_cache"].contains(url.lastPathComponent)
        }
        if self == .installers { return ["dmg", "pkg", "mpkg", "ipsw", "iso"].contains(url.pathExtension.lowercased()) }
        if self == .iphoneFirmware || self == .ipadFirmware { return url.pathExtension.lowercased() == "ipsw" }
        if self == .macInstallers {
            guard url.pathExtension.lowercased() == "app", let id = Bundle(url: url)?.bundleIdentifier else { return false }
            return id == "com.apple.InstallAssistant" || id.hasPrefix("com.apple.InstallAssistant.")
        }
        return true
    }
}

struct Inventory: Equatable, Sendable, Codable {
    var bytes: Int64 = 0
    var entries: Int = 0
    var newest: Date = .distantPast
}

struct Candidate: Identifiable, Sendable, Codable {
    var id: String { url.path }
    let url: URL
    let category: Category
    let inventory: Inventory
    var minimumAge: TimeInterval? = nil
    var backup: BackupMetadata? = nil
    var name: String {
        if let name = backup?.deviceName { return name }
        if category == .electronCaches { return "\(url.deletingLastPathComponent().lastPathComponent) · \(url.lastPathComponent)" }
        if category == .chromeProfiles { return "Chrome · \(url.deletingLastPathComponent().lastPathComponent) · \(url.lastPathComponent)" }
        if category == .cache && url.lastPathComponent == "Codex" { return "ChatGPT／Codex" }
        if category == .cache && url.lastPathComponent == "Google" { return "Google（含 Chrome）" }
        return url.lastPathComponent
    }
}

struct ScanResult: Sendable {
    var candidates: [Candidate] = []
    var notes: [String] = []
}

enum CleanerError: LocalizedError {
    case recent
    case unsafe(String)
    case changed
    var errorDescription: String? {
        switch self {
        case .recent: return "項目仍有近期修改，已略過。"
        case .unsafe(let message): return message
        case .changed: return "項目自掃描後已變更；請重新掃描。"
        }
    }
}

/// Works only on direct children of three explicit user Library folders.
/// No shell commands, recursive deletion, elevated privileges, or symlink traversal.
struct Cleaner: Sendable {
    let home: URL
    private var fm: FileManager { FileManager.default }
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
    }

    func root(_ category: Category) -> URL {
        if category == .macInstallers || category == .macUpdates {
            // Isolated homes used by tests never inspect the host's system folders.
            let liveHome = fm.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
            let base = home.path == liveHome.path ? URL(fileURLWithPath: "/") : home.appendingPathComponent("SystemFixture")
            return base.appendingPathComponent(category.relativePath).standardizedFileURL
        }
        return home.appendingPathComponent(category.relativePath).standardizedFileURL
    }

    func validate(_ url: URL, category: Category) throws {
        let base = root(category)
        let item = url.standardizedFileURL
        let directChild = item.deletingLastPathComponent().path == base.path
        let profile = item.deletingLastPathComponent()
        let profileCache = category == .chromeProfiles && profile.deletingLastPathComponent().path == base.path
            && Self.isChromeProfile(profile.lastPathComponent) && Self.chromeCacheNames.contains(item.lastPathComponent)
        let electronCache = category == .electronCaches && electronCacheURLs().contains { $0.path == item.path }
        guard !excluded(item, category: category), category.accepts(item), base.resolvingSymlinksInPath().path == base.path,
              category == .installers ? installerPathAllowed(item) : (category == .electronCaches ? electronCache : (category == .chromeProfiles ? profileCache : directChild)),
              item.path == url.path,
              item.resolvingSymlinksInPath().path == item.path else {
            throw CleanerError.unsafe("路徑不在允許範圍內，或包含符號連結。")
        }
        let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw CleanerError.unsafe("略過符號連結。")
        }
    }

    static let chromeCacheNames = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]
    static func isChromeProfile(_ name: String) -> Bool {
        name == "Default" || (name.hasPrefix("Profile ") && Int(name.dropFirst(8)).map { $0 >= 0 } == true)
    }

    func excluded(_ url: URL, category: Category) -> Bool {
        // Never offer a parent that would also remove sync/offline content.
        if category == .support && ["Google", "Google Drive", "DriveFS", "MobileSync"].contains(url.lastPathComponent) { return true }
        if category == .cache && ["Google", "Google Drive", "DriveFS", "com.google.drivefs", "com.google.GoogleDrive"].contains(url.lastPathComponent) { return true }
        if category == .cache {
            let name = url.lastPathComponent.lowercased()
            // Sync/backup state and aggregate metadata are not disposable cache by default.
            if ["cloudkit", "icloud", "com.backup42.desktop", "com.pogoplug.backup", "metadata"].contains(name)
                || name.hasPrefix("com.dropbox.mbd.external.") { return true }
        }
        return url.lastPathComponent == ".DS_Store"
    }

    func inventory(_ url: URL, cancellation: ScanCancellation? = nil, olderThan: Date? = nil) throws -> Inventory {
        try cancellation?.check()
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey]
        let first = try url.resourceValues(forKeys: keys)
        if let olderThan, (first.contentModificationDate ?? .distantFuture) >= olderThan {
            throw CleanerError.recent
        }
        guard first.isSymbolicLink != true else { throw CleanerError.unsafe("略過符號連結。") }
        var result = Inventory()
        func include(_ values: URLResourceValues) {
            result.entries += 1
            result.newest = max(result.newest, values.contentModificationDate ?? .distantFuture)
            if values.isRegularFile == true { result.bytes += Int64(values.fileSize ?? 0) }
        }
        include(first)
        if first.isDirectory == true {
            var failure: Error?
            guard let iterator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                               options: [], errorHandler: { _, error in
                failure = error
                return false
            }) else { throw CleanerError.unsafe("無法完整讀取資料夾。") }
            for case let child as URL in iterator {
                try cancellation?.check()
                try Task.checkCancellation()
                let values = try child.resourceValues(forKeys: keys)
                if let olderThan, (values.contentModificationDate ?? .distantFuture) >= olderThan {
                    throw CleanerError.recent
                }
                // Exclude the entire candidate if it contains links; never follow their targets.
                guard values.isSymbolicLink != true else {
                    throw CleanerError.unsafe("資料夾包含符號連結，為安全起見略過。")
                }
                include(values)
            }
            if let failure { throw failure }
        }
        return result
    }

    func scan(includeSupport: Bool, now: Date = Date(), cancellation: ScanCancellation? = nil, deep: Bool = false,
              skip: Set<String> = [], event: (ScanEvent) -> Void = { _ in }) throws -> ScanResult {
        var result = ScanResult()
        for category in Category.allCases where includeSupport || category != .support {
            if !deep && category != .cache && category != .logs && category != .support { continue }
            try cancellation?.check()
            try Task.checkCancellation()
            let base = root(category)
            if skip.contains(base.path) { continue }
            event(ScanEvent(kind: "checking", path: base.path))
            guard fm.fileExists(atPath: base.path) else { continue }
            guard base.resolvingSymlinksInPath().path == base.path else {
                result.notes.append("\(base.path)：路徑包含符號連結，已略過。")
                continue
            }
            do {
                var children = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
                if category == .installers {
                    let downloadResult = try downloadInstallers(cancellation: cancellation, skip: skip, event: event)
                    children = downloadResult.0
                    result.notes.append(contentsOf: downloadResult.1)
                    for note in downloadResult.1 { event(ScanEvent(kind: "note", path: note)) }
                }
                if category == .electronCaches { children = electronCacheURLs() }
                if category == .chromeProfiles {
                    children = children.filter { Self.isChromeProfile($0.lastPathComponent) }.flatMap { profile in
                        Self.chromeCacheNames.map { profile.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
                    }
                }
                for entry in children {
                    try cancellation?.check()
                    let child = entry.standardizedFileURL
                    guard category.accepts(child), !excluded(child, category: category) else { continue }
                    if skip.contains(child.path) { continue }
                    event(ScanEvent(kind: "checking", path: child.path))
                    defer { event(ScanEvent(kind: "checked", path: child.path)) }
                    try Task.checkCancellation()
                    do {
                        try validate(child, category: category)
                        let age = deep ? 0 : category.age
                        let details = try inventory(child, cancellation: cancellation,
                                                    olderThan: age == 0 ? nil : now.addingTimeInterval(-age))
                        // The newest descendant must also satisfy the age threshold.
                        guard details.bytes > 0,
                              age == 0 || details.newest < now.addingTimeInterval(-age)
                        else { continue }
                        result.candidates.append(Candidate(url: child, category: category, inventory: details, minimumAge: age,
                                                           backup: category == .backups ? BackupMetadata.read(at: child) : nil))
                        event(ScanEvent(kind: "candidate", candidate: result.candidates.last))
                    } catch is CancellationError { throw CancellationError() }
                    catch CleanerError.recent { }
                    catch {
                        let note = "\(child.path)：\(error.localizedDescription)"
                        result.notes.append(note)
                        event(ScanEvent(kind: "note", path: note))
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                let note = "\(base.path)：\(error.localizedDescription)"
                result.notes.append(note)
                event(ScanEvent(kind: "note", path: note))
            }
        }
        result.candidates = uniqueCandidates(result.candidates)
        return result
    }

    @discardableResult
    func trash(_ candidate: Candidate) throws -> URL? {
        guard !candidate.category.readOnly else { throw CleanerError.unsafe("系統管理的更新資料僅供查看，不提供刪除。") }
        try validate(candidate.url, category: candidate.category)
        let current = try inventory(candidate.url)
        guard current == candidate.inventory else { throw CleanerError.changed }
        let age = candidate.minimumAge ?? candidate.category.age
        if age > 0 {
            guard current.newest < Date().addingTimeInterval(-age) else {
                throw CleanerError.changed
            }
        }
        try validate(candidate.url, category: candidate.category)
        var destination: NSURL?
        try fm.trashItem(at: candidate.url, resultingItemURL: &destination)
        return destination as URL?
    }
}

func formattedBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

func uniqueCandidates(_ items: [Candidate]) -> [Candidate] {
    var result: [Candidate] = []
    for item in items.sorted(by: { $0.id.count < $1.id.count }) {
        if !result.contains(where: { item.id == $0.id || item.id.hasPrefix($0.id + "/") }) {
            result.append(item)
        }
    }
    return markLatestBackups(result).sorted { $0.inventory.bytes > $1.inventory.bytes }
}
