import SwiftUI
import AppKit

@MainActor
final class Model: ObservableObject {
    private let cleaner: Cleaner = {
        #if UI_TEST
        guard let path = Bundle.main.object(forInfoDictionaryKey: "MacSweepTestHome") as? String else {
            fatalError("UI test build requires an isolated fixture home")
        }
        return Cleaner(home: URL(fileURLWithPath: path))
        #else
        return Cleaner()
        #endif
    }()
    @Published var items: [Candidate] = []
    @Published var selected: Set<String> = []
    @Published var notes: [String] = []
    @Published var includeSupport = false
    @Published var deepScan = true
    @Published var busy = false
    @Published var scanning = false
    @Published var status = "先掃描，再決定要清理哪些項目。"
    @Published var hasScanned = false
    private var scanCancellation: ScanCancellation?
    var selectedItems: [Candidate] { items.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.inventory.bytes } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.inventory.bytes } }

    func scan() {
        busy = true
        scanning = true
        selected.removeAll()
        items.removeAll()
        notes.removeAll()
        status = "正在檢查使用者資料夾；大型資料夾可能需要幾分鐘…"
        let support = includeSupport
        let deep = deepScan
        let cleaner = self.cleaner
        #if UI_TEST
        status = "UI TEST v2：\(cleaner.home.path)"
        #endif
        let cancellation = ScanCancellation()
        scanCancellation = cancellation
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                try ScannerWorker(executable: Bundle.main.executableURL!).scan(
                    home: cleaner.home, support: support, deep: deep, cancellation: cancellation
                ) { path, count in
                    DispatchQueue.main.async {
                        guard self.scanCancellation === cancellation else { return }
                        self.status = "已檢查 \(count) 個項目 · \(path)"
                    }
                }
            }
            DispatchQueue.main.async {
                do {
                    try cancellation.check()
                    let result = try outcome.get()
                    self.items = result.candidates
                    self.notes = result.notes
                    self.hasScanned = true
                    self.status = "掃描結束：\(self.items.count) 個可檢查項目，\(self.notes.count) 個略過或限制。"
                } catch is CancellationError {
                    self.status = "已取消掃描，沒有移除任何資料。"
                } catch { self.status = "掃描失敗：\(error.localizedDescription)" }
                self.busy = false
                self.scanning = false
                self.scanCancellation = nil
            }
        }
    }

    func cancel() { scanCancellation?.cancel() }

    func confirmTrash() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "將 \(targets.count) 個項目移到垃圾桶？"
        var text = "選取大小：\(formattedBytes(selectedBytes))。請先關閉相關 App，避免使用中的資料被搬移。\n\n快取可能會重新建立；日誌可能包含診斷紀錄。移到垃圾桶不會立即釋放磁碟空間，還需要你自行清空垃圾桶。"
        if targets.contains(where: { $0.category == .support }) {
            text += "\n\n你選取了 App 資料，可能含有文件、帳號、設定或資料庫。這些項目尚未被判定為卸載殘留；請確定不再需要，且已有備份。"
        }
        if targets.contains(where: { $0.category == .backups || $0.category == .archives }) {
            text += "\n\n你選取了裝置備份或 Xcode 封存，它們不是一般暫存。移除後可能失去裝置還原、舊版本發布或除錯所需的資料。"
        }
        if targets.contains(where: { $0.backup?.isLatest == true }) {
            text += "\n\n其中包含此裝置最新已辨識的備份。請確認還有其他可用的還原來源。"
        }
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移到垃圾桶")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        status = "正在重新檢查並移到垃圾桶…"
        let cleaner = self.cleaner
        DispatchQueue.global(qos: .userInitiated).async {
                var removed: Set<String> = []
                var errors: [String] = []
                for item in targets {
                    do {
                        let destination = try cleaner.trash(item)
                        removed.insert(item.id)
                        #if UI_TEST
                        if let destination {
                            let payload = try String(contentsOf: destination.appendingPathComponent("fixture.txt"), encoding: .utf8)
                            let receipt = "Original exists: \(FileManager.default.fileExists(atPath: item.url.path))\nTrash destination: \(destination.path)\nVerified payload: \(payload)\n"
                            try receipt.write(to: cleaner.home.appendingPathComponent("trash-receipt.txt"), atomically: true, encoding: .utf8)
                        }
                        #else
                        _ = destination
                        #endif
                    }
                    catch { errors.append("\(item.url.path)：\(error.localizedDescription)") }
                }
            let outcome = (removed, errors)
            DispatchQueue.main.async {
                self.items.removeAll { outcome.0.contains($0.id) }
                self.selected.subtract(outcome.0)
                self.notes.append(contentsOf: outcome.1)
                self.status = "已移到垃圾桶：\(outcome.0.count) 個；未移動：\(outcome.1.count) 個。"
                self.busy = false
            }
        }
    }
}

struct MacSweepApp: App {
    @StateObject private var model = Model()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("MacSweep") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 660)
        }
        .defaultSize(width: 1120, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@main
enum EntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--leftovers-worker" {
            leftoversWorkerMain(CommandLine.arguments[2])
        } else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--inspect-worker" {
            appInspectionWorkerMain(CommandLine.arguments[2])
        } else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--scan-worker" {
            scanWorkerMain(CommandLine.arguments[2])
        } else {
            MacSweepApp.main()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var filter = ""
    @State private var category: Category?
    @State private var showNotes = false
    private let accent = Color(red: 0.12, green: 0.64, blue: 0.54)
    var visible: [Candidate] {
        model.items.filter {
            (category == nil || $0.category == category || (category == .installers && $0.category.isInstaller) ||
             (category == .cache && $0.category.isCache) || (category == .logs && $0.category == .driveLogs)) &&
            (filter.isEmpty || $0.url.path.localizedCaseInsensitiveContains(filter) || $0.name.localizedCaseInsensitiveContains(filter))
        }.sorted { lhs, rhs in
            if category == .backups {
                let left = lhs.backup?.deviceID ?? lhs.id, right = rhs.backup?.deviceID ?? rhs.id
                if left != right { return left < right }
                return (lhs.backup?.date ?? .distantPast) > (rhs.backup?.date ?? .distantPast)
            }
            return lhs.inventory.bytes > rhs.inventory.bytes
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.title).foregroundStyle(accent)
                    Text("MacSweep").font(.title2.bold())
                }.padding(.top, 20)
                Text("讓空間回到你手中").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    sidebarButton("所有項目", icon: "square.grid.2x2", value: nil)
                    sidebarButton("快取", icon: "externaldrive", value: .cache)
                    sidebarButton("日誌", icon: "doc.text", value: .logs)
                    sidebarButton("App 卸載", icon: "shippingbox", value: .support)
                    sidebarButton("開發暫存", icon: "hammer", value: .developer)
                    sidebarButton("Xcode 封存", icon: "archivebox", value: .archives)
                    sidebarButton("裝置備份", icon: "iphone", value: .backups)
                    sidebarButton("安裝與更新檔", icon: "opticaldisc", value: .installers)
                }
                Spacer()
                Label("本機處理", systemImage: "lock.shield")
                    .font(.headline).foregroundStyle(accent)
                Text("不連網、不要求管理員權限。\n每次移動前都由你確認。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
                Text("MacSweep · 1.17").font(.caption2).foregroundStyle(.tertiary)
            }.padding(24).frame(width: 222).frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if category == .support {
                ApplicationsView()
            } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("檢查與清理").font(.system(size: 28, weight: .bold))
                        Text("先看清楚，再安心整理。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.scanning {
                        ProgressView().controlSize(.small)
                        Button("取消", action: model.cancel)
                    } else {
                        Button(action: model.scan) {
                            Label(model.hasScanned ? "重新掃描" : "開始掃描", systemImage: "magnifyingglass")
                        }.buttonStyle(.borderedProminent).tint(accent).disabled(model.busy)
                    }
                }
                HStack(spacing: 12) {
                    metric("待檢查大小", value: formattedBytes(model.totalBytes))
                    metric("已選取大小", value: formattedBytes(model.selectedBytes))
                    metric("已選取項目", value: "\(model.selected.count)")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("掃描範圍：使用者資料、下載的安裝檔與 macOS 安裝程式").font(.headline)
                    Picker("掃描深度", selection: $model.deepScan) {
                        Text("深度掃描").tag(true)
                        Text("保守：僅舊快取與舊日誌").tag(false)
                    }.pickerStyle(.segmented).disabled(model.busy)
                    Text(model.deepScan ? "完整快取、日誌、開發暫存、裝置備份、DMG／PKG／IPSW 與 macOS 安裝程式。全部預設不勾選。" : "快取超過 7 天、日誌超過 30 天未修改。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("備份與封存不是垃圾，請確認不再需要。App 設定與專用文件請至左側「App 卸載」。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                if category == .backups {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("備份位置：~/Library/Application Support/MobileSync/Backup/").font(.caption)
                        if model.notes.contains(where: { $0.contains("MobileSync/Backup") }) {
                            Text("備份掃描未完成，請查看略過紀錄。若是權限不足，可在系統設定的「隱私權與安全性 → 完全磁碟存取」加入 MacSweep，再結束並重新開啟 App。")
                                .font(.caption).foregroundStyle(.orange)
                            Button("開啟系統設定") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                            }.font(.caption)
                        }
                    }
                }
                if category == .cache {
                    Text("Chrome 與 Claude 的已知快取已納入；Safari／ChatGPT 沙盒快取需有讀取權限。Google Drive 同步與離線內容不列入清理清單。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("搜尋名稱或路徑", text: $filter).textFieldStyle(.roundedBorder)
                    Text("本頁 \(visible.count) 項 · \(formattedBytes(visible.reduce(0) { $0 + $1.inventory.bytes }))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("取消選取") { model.selected.removeAll() }
                        .disabled(model.busy || model.selected.isEmpty)
                }
                if visible.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: model.scanning ? "externaldrive.badge.magnifyingglass" : "tray")
                            .font(.system(size: 38)).foregroundStyle(accent)
                        Text(model.scanning ? "正在掃描…" : model.hasScanned ? "沒有符合條件的項目" : "準備好檢查你的 Mac")
                            .font(.headline)
                        Text("掃描不會移動或刪除資料。所有項目預設不勾選。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                                if category == .backups && (index == 0 || (visible[index - 1].backup?.deviceID ?? visible[index - 1].id) != (item.backup?.deviceID ?? item.id)) {
                                    Text(item.backup?.deviceName ?? "未辨識的裝置")
                                        .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                                }
                                HStack(spacing: 12) {
                                    Toggle("選取 \(item.name)", isOn: Binding(
                                        get: { model.selected.contains(item.id) },
                                        set: { if $0 { model.selected.insert(item.id) } else { model.selected.remove(item.id) } }
                                    )).labelsHidden().toggleStyle(.checkbox).disabled(model.busy || item.category.readOnly)
                                    Image(systemName: item.category == .backups ? "iphone" : "folder")
                                        .font(.title2).foregroundStyle(item.category == .backups || item.category == .archives ? .orange : accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Text(item.url.path).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle).help(item.url.path)
                                        Text("\(item.category.rawValue) · 最後修改 \(item.inventory.newest.formatted(date: .numeric, time: .omitted))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        if let backup = item.backup {
                                            Text(backup.detail).font(.caption2).foregroundStyle(backup.isLatest ? .orange : .secondary)
                                            if let id = backup.deviceID { Text("裝置識別：\(id)").font(.caption2).foregroundStyle(.secondary) }
                                        }
                                        if item.category.readOnly { Text("系統管理，僅供查看").font(.caption2).foregroundStyle(.orange) }
                                    }
                                    Spacer(minLength: 4)
                                    Text(formattedBytes(item.inventory.bytes)).monospacedDigit().font(.callout)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                                        Image(systemName: "arrow.up.forward.square")
                                    }.buttonStyle(.borderless).help("在 Finder 中查看")
                                }.padding(.vertical, 12).padding(.horizontal, 8)
                                Divider()
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                        if !model.notes.isEmpty {
                            Button("查看 \(model.notes.count) 個略過或失敗紀錄") { showNotes = true }
                                .buttonStyle(.link).font(.caption)
                        }
                        Text("移到垃圾桶後，空間尚未釋放。可至垃圾桶查看或手動還原。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("移到垃圾桶…", action: model.confirmTrash)
                        .buttonStyle(.borderedProminent).tint(accent)
                        .disabled(model.busy || model.selected.isEmpty)
                }
            }.padding(28)
            }
        }
        .sheet(isPresented: $showNotes) {
            VStack(alignment: .leading, spacing: 16) {
                Text("略過與失敗紀錄").font(.title2.bold())
                Text("讀取不到或含有符號連結的項目會略過，不會強制取得權限。")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView { Text(model.notes.joined(separator: "\n\n"))
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading) }
                Button("關閉") { showNotes = false }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 720, height: 440)
        }
    }

    func sidebarButton(_ title: String, icon: String, value: Category?) -> some View {
        Button { category = value } label: {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                .background(category == value ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).foregroundStyle(category == value ? accent : .primary)
    }

    func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
