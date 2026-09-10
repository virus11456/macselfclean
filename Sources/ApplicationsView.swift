import SwiftUI
import AppKit

@MainActor
final class AppsModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var rememberedApps: [InstalledApp] = []
    private let locationStore = AppLocationStore(defaults: .standard)
    private var locationLoadFailed = false
    @Published var busy = false
    @Published var inspecting = false
    private var inspectionCancellation: ScanCancellation?
    @Published var status = "列出可卸載 App；其他安裝位置可手動加入。"
    @Published var plan: UninstallPlan?
    @Published var selected: Set<String> = []
    @Published var messages: [String] = []
    @Published var lastReport: UninstallReport?
    @Published var reportNotice: String?
    private let reportStore = UninstallReportStore(defaults: .standard)

    init() {
        do { lastReport = try reportStore.load() }
        catch { reportNotice = "無法讀取已儲存的卸載紀錄：\(error.localizedDescription)；可以清除紀錄後重新開始。" }
    }
    func clearReport() {
        reportStore.clear()
        lastReport = nil
        reportNotice = nil
    }
    let catalog: AppCatalog = {
        #if UI_TEST
        return AppCatalog(home: URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MacSweepTestHome") as! String))
        #else
        return AppCatalog(home: FileManager.default.homeDirectoryForCurrentUser)
        #endif
    }()
    func refresh() {
        busy = true
        status = "正在讀取已安裝 App…"
        do {
            rememberedApps = try locationStore.load()
            locationLoadFailed = false
        } catch {
            locationLoadFailed = true
            messages = ["無法讀取已儲存的其他位置，已停止檢查；請先重設記錄。"]
            status = "其他位置記錄無法讀取。"
            busy = false
            return
        }
        let catalog = catalog, remembered = rememberedApps
        DispatchQueue.global(qos: .userInitiated).async {
            var (apps, notes) = catalog.list()
            for known in remembered {
                if let current = catalog.readApp(known.url), current.bundleID == known.bundleID, current.name == known.name {
                    if !current.protected && !apps.contains(where: { $0.id == current.id }) { apps.append(current) }
                } else {
                    notes.append("其他位置已變更或無法讀取：\(known.url.path)。記錄已保留；請重新連接磁碟、重新加入，或從「其他位置記錄」移除。")
                }
            }
            apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.apps = apps
                self.messages = notes
                self.status = "找到 \(apps.count) 個可卸載 App · 已隱藏系統與受保護項目"
                self.busy = false
            }
        }
    }
    func addApp() {
        let picker = NSOpenPanel()
        picker.message = "選擇其他位置的 .app 程式"
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        guard !locationLoadFailed else { return }
        var updated = rememberedApps
        for url in picker.urls {
            if let app = catalog.readApp(url), !app.protected {
                updated.removeAll { $0.id == app.id }
                updated.append(app)
            }
        }
        saveLocations(updated)
    }
    func saveLocations(_ locations: [InstalledApp]) {
        do { try locationStore.save(locations); refresh() }
        catch { messages = ["無法儲存其他位置：\(error.localizedDescription)"] }
    }
    func inspect(_ app: InstalledApp) {
        guard !locationLoadFailed else { return }
        busy = true
        status = "正在檢查 \(app.name) 的關聯資料…"
        inspecting = true
        let cancellation = ScanCancellation()
        inspectionCancellation = cancellation
        let catalog = catalog, installed = rememberedApps + apps.filter { current in !rememberedApps.contains { $0.id == current.id } }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                try AppInspectionWorker(executable: Bundle.main.executableURL!).inspect(home: catalog.home, app: app, installed: installed, cancellation: cancellation)
            }
            DispatchQueue.main.async {
                do {
                    try cancellation.check()
                    let plan = try outcome.get()
                    self.plan = plan
                    self.selected = Set(plan.files.filter { !$0.review }.map(\.id))
                    self.status = "已列出 \(app.name) 的卸載明細。"
                } catch is CancellationError { self.status = "已取消卸載檢查，沒有移動任何資料。" }
                catch { self.status = error.localizedDescription }
                self.busy = false
                self.inspecting = false
                self.inspectionCancellation = nil
            }
        }
    }
    func cancelInspection() { inspectionCancellation?.cancel() }

    func uninstall() {
        guard let plan, selected.contains(plan.app.id) else { return }
        let alert = NSAlert()
        alert.messageText = "卸載 \(plan.app.name)，並移除所選的關聯資料？"
        alert.informativeText = "共 \(selected.count) 個項目，將移到垃圾桶。所選的專用資料可能包含文件、帳號與設定。請先備份需要的內容並結束 App。\n\n名稱相符但歸屬不明的資料，只有你勾選後才會處理。遇到第一個搬移失敗就會停止，列出已移動與未移動的路徑；已移動的項目不會自動還原。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "確認卸載並移到垃圾桶")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        let catalog = catalog, selection = selected
        DispatchQueue.global(qos: .userInitiated).async {
            let (removed, errors) = catalog.uninstall(plan, selected: selection)
            DispatchQueue.main.async {
                let report = UninstallReport(appName: plan.app.name, selected: selection, moved: removed, errors: errors)
                self.lastReport = report
                do { try self.reportStore.save(report); self.reportNotice = nil }
                catch { self.reportNotice = "本次紀錄未儲存，請先複製；重開後可能仍是前次紀錄：\(error.localizedDescription)" }
                let remaining = report.remaining
                self.messages = errors + removed.map { "已移到垃圾桶：\($0)" }
                    + remaining.map { "未移動：\($0)" }
                self.status = errors.isEmpty
                    ? "卸載完成：已移到垃圾桶 \(removed.count) 項。"
                    : "卸載已停止：已移動 \(removed.count) 項，未移動 \(remaining.count) 項。已移動的項目可至垃圾桶手動還原。"
                if removed.contains(plan.app.id) {
                    self.apps.removeAll { $0.id == plan.app.id }
                    self.rememberedApps.removeAll { $0.id == plan.app.id }
                    do { try self.locationStore.save(self.rememberedApps) }
                    catch { self.messages.append("卸載後無法更新其他位置記錄：\(error.localizedDescription)") }
                }
                self.plan = nil
                self.selected = []
                self.busy = false
            }
        }
    }
}

struct ApplicationsView: View {
    @StateObject private var model = AppsModel()
    @State private var query = ""
    @State private var showLeftovers = false
    @State private var showReport = false
    private let accent = Color(red: 0.12, green: 0.64, blue: 0.54)
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("App 與關聯資料").font(.system(size: 28, weight: .bold))
                    Text("從程式本體到專用設定與文件，一起檢查再卸載。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("加入其他位置…", action: model.addApp).disabled(model.busy)
                Menu("其他位置記錄") {
                    ForEach(model.rememberedApps) { app in
                        Button("移除記錄：\(app.url.path)") {
                            model.saveLocations(model.rememberedApps.filter { $0.id != app.id })
                        }
                    }
                    Button("清除所有位置記錄（不刪除檔案）") { model.saveLocations([]) }
                }.disabled(model.busy)
                Button("重新整理", action: model.refresh).disabled(model.busy)
            }
            Picker("檢查內容", selection: $showLeftovers) {
                Text("已安裝 App").tag(false)
                Text("待確認殘留").tag(true)
            }.pickerStyle(.segmented)
            if showLeftovers {
                LeftoversView(installed: model.apps + model.rememberedApps, home: model.catalog.home)
            } else {
            TextField("搜尋 App 名稱或識別碼", text: $query).textFieldStyle(.roundedBorder)
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    if model.inspecting { Button("取消檢查", action: model.cancelInspection) }
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }) { app in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.headline)
                                Text("\(app.version) · \(app.bundleID)").font(.caption).foregroundStyle(.secondary)
                                Text(app.url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if app.protected { Label("受保護", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
                            else { Button("檢查並卸載…") { model.inspect(app) }.disabled(model.busy) }
                        }.padding(.vertical, 12)
                        Divider()
                    }
                }
            }
            }
            HStack {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("上次卸載紀錄") { showReport = true }
                    .disabled(model.lastReport == nil || model.busy)
                    .sheet(isPresented: $showReport) {
                        if let report = model.lastReport {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("\(report.appName) 卸載紀錄").font(.title2.bold())
                                Text(report.summary).font(.headline)
                                ScrollView {
                                    Text(report.text).font(.callout).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Text("本機只保存最後一筆卸載紀錄，包含檔案路徑；下一次操作會取代。需要長期留存請複製。")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("複製紀錄") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(report.text, forType: .string)
                                    }
                                    Spacer()
                                    Button("關閉") { showReport = false }
                                }
                            }.padding(24).frame(width: 740, height: 540)
                        }
                    }
            }
            if model.lastReport != nil || model.reportNotice != nil {
                HStack {
                    if let notice = model.reportNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button("清除卸載紀錄（不刪除檔案）", action: model.clearReport).disabled(model.busy)
                }
            }
            if !model.messages.isEmpty {
                ScrollView { Text(model.messages.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                    .frame(maxHeight: 90)
            }
            Text("共用資料、系統服務與其他位置的個人作品不會自動刪除；卸載前請先結束 App。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(28)
            .onAppear { if model.apps.isEmpty { model.refresh() } }
            .sheet(isPresented: Binding(get: { model.plan != nil }, set: { if !$0 && !model.busy { model.plan = nil } })) {
                if let plan = model.plan {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("卸載 \(plan.app.name)").font(.title2.bold())
                        Text("確認關聯檔案，勾選要一起移除的資料。\n橘色項目需要你確認歸屬或是否保留，預設不勾選。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("已選 \(formattedBytes(plan.files.filter { model.selected.contains($0.id) }.reduce(0) { $0 + $1.bytes })) · 邏輯大小，非保證可釋放空間")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(AppFileGroup.allCases) { group in
                                    let groupFiles = plan.files.filter { $0.group == group }
                                    if !groupFiles.isEmpty {
                                        HStack {
                                            Text(group.rawValue).font(.headline)
                                            Spacer()
                                            Text("已選 \(groupFiles.filter { model.selected.contains($0.id) }.count)／\(groupFiles.count) 項 · \(formattedBytes(groupFiles.reduce(0) { $0 + $1.bytes }))").font(.caption).foregroundStyle(.secondary)
                                        }.padding(.top, 8)
                                    }
                                ForEach(groupFiles) { file in
                                    HStack(alignment: .top) {
                                        Toggle("選取 \(file.url.lastPathComponent)", isOn: Binding(
                                            get: { model.selected.contains(file.id) },
                                            set: { if $0 { model.selected.insert(file.id) } else { model.selected.remove(file.id) } }
                                        )).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.url.lastPathComponent).font(.headline)
                                            Text(file.reason).font(.caption).foregroundStyle(file.review ? .orange : .secondary)
                                            Text(file.url.path).font(.caption2).textSelection(.enabled)
                                        }
                                        Spacer()
                                        Text(formattedBytes(file.bytes)).font(.caption).monospacedDigit()
                                        Button("查看") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                    }
                                    Divider()
                                }
                                }
                                ForEach(plan.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        HStack {
                            Button("返回") { model.plan = nil }.disabled(model.busy)
                            Spacer()
                            if model.busy { ProgressView().controlSize(.small) }
                            Button("卸載所選 \(model.selected.count) 個項目…", action: model.uninstall)
                                .buttonStyle(.borderedProminent).tint(accent)
                                .disabled(model.busy || !model.selected.contains(plan.app.id))
                        }
                    }.padding(24).frame(width: 800, height: 610)
                        .interactiveDismissDisabled(model.busy)
                }
            }
    }
}
