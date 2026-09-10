import Foundation

struct UninstallReport: Sendable, Codable {
    let appName: String
    let date: Date
    let moved: [String]
    let remaining: [String]
    let errors: [String]

    init(appName: String, date: Date = Date(), selected: Set<String>, moved: [String], errors: [String]) {
        self.appName = appName
        self.date = date
        let confirmed = Set(moved).intersection(selected)
        self.moved = confirmed.sorted()
        self.remaining = selected.subtracting(confirmed).sorted()
        self.errors = errors
    }
    var summary: String {
        let outcome = errors.isEmpty && remaining.isEmpty ? "卸載完成" : "卸載未完成"
        return "\(outcome)：已移動 \(moved.count) 項，未移動 \(remaining.count) 項。"
    }
    var text: String {
        var lines = ["MacSweep 卸載紀錄", "App：\(appName)", "時間：\(ISO8601DateFormatter().string(from: date))", summary]
        if !errors.isEmpty { lines += ["", "停止原因／錯誤"] + errors }
        lines += ["", "已移到垃圾桶（\(moved.count) 項）"] + moved
        lines += ["", "未移動（\(remaining.count) 項，包含失敗或尚未處理）"] + remaining
        lines += ["", "已移動項目不會自動還原，請至垃圾桶檢查並手動還原。此紀錄只描述本次操作，不代表路徑目前狀態。"]
        return lines.joined(separator: "\n")
    }
}

struct UninstallReportStore {
    let defaults: UserDefaults
    var key = "MacSweep.lastUninstallReport.v1"
    var maximumBytes = 4 * 1024 * 1024

    func load() throws -> UninstallReport? {
        guard let stored = defaults.object(forKey: key) else { return nil }
        guard let data = stored as? Data, data.count <= maximumBytes else {
            throw CleanerError.unsafe("卸載紀錄格式不符或過大。")
        }
        return try JSONDecoder().decode(UninstallReport.self, from: data)
    }
    func save(_ report: UninstallReport) throws {
        let data = try JSONEncoder().encode(report)
        guard data.count <= maximumBytes else { throw CleanerError.unsafe("卸載紀錄過大，請複製留存。") }
        defaults.set(data, forKey: key)
    }
    func clear() { defaults.removeObject(forKey: key) }
}
