import SwiftUI
import AppKit

struct LeftoversView: View {
    @State private var items: [Leftover] = []
    @State private var notes: [String] = []
    @State private var busy = false
    @State private var searched = false
    @State private var query = ""
    @State private var cancellation: ScanCancellation?
    @State private var status = "按「檢查殘留」開始，掃描不會改動檔案。"
    let installed: [InstalledApp]
    let home: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("待確認殘留").font(.title2.bold())
            Text("檢查設定、快取與日誌中未找到對應 App 的項目。未找到不代表無用：背景工具、外接磁碟或未登記的 App 仍可能需要它們。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("搜尋識別碼或路徑", text: $query).textFieldStyle(.roundedBorder)
                Button(searched ? "重新檢查" : "檢查殘留", action: scan).disabled(busy)
            }
            if busy { HStack { ProgressView(); Button("取消檢查") { cancellation?.cancel() } } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(items.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.bundleID).font(.headline)
                                Text(item.file.url.path).font(.caption).textSelection(.enabled)
                                Text(item.file.reason).font(.caption2).foregroundStyle(.orange)
                            }
                            Spacer()
                            Text(formattedBytes(item.file.bytes)).font(.caption).monospacedDigit()
                            Button("在 Finder 檢查") { NSWorkspace.shared.activateFileViewerSelecting([item.file.url]) }
                        }
                        Divider()
                    }
                }
            }
            Text(status)
                .font(.caption).foregroundStyle(.secondary)
            if !notes.isEmpty {
                ScrollView { Text(notes.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 75)
            }
            Text("此頁只提供檢查，不自動判定垃圾或批次移除。Google Drive、Apple 系統資料與 App 專用文件不納入本頁。")
                .font(.caption2).foregroundStyle(.secondary)
        }.onDisappear { cancellation?.cancel() }
    }
    func scan() {
        busy = true
        items = []
        notes = []
        status = "正在比對安裝清單與殘留候選…"
        let token = ScanCancellation()
        cancellation = token
        let request = LeftoversRequest(home: home, installed: installed)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                let result: LeftoversResult = try AppInspectionWorker(executable: Bundle.main.executableURL!).run(
                    request: request, mode: "--leftovers-worker", label: "殘留檢查", cancellation: token)
                return result
            }
            DispatchQueue.main.async {
                guard cancellation === token else { return }
                do {
                    try token.check()
                    let result = try outcome.get()
                    items = result.items
                    notes = result.notes
                    status = notes.isEmpty ? "檢查完成：\(items.count) 個待確認項目 · \(formattedBytes(items.reduce(0) { $0 + $1.file.bytes }))。"
                        : "檢查未完整完成：\(items.count) 個待確認項目，\(notes.count) 個讀取限制；不能據此判斷沒有殘留。"
                } catch is CancellationError { status = "已取消殘留檢查，沒有移動任何資料。" }
                catch { status = "檢查未完成：\(error.localizedDescription)" }
                searched = true
                busy = false
                cancellation = nil
            }
        }
    }
}
