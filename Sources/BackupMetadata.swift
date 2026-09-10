import Foundation

struct BackupMetadata: Sendable, Codable {
    var deviceName: String?
    var deviceID: String?
    var date: Date?
    var completed: Bool
    var isLatest: Bool = false

    static func read(at folder: URL) -> BackupMetadata {
        func plist(_ name: String) -> [String: Any] {
            let url = folder.appendingPathComponent(name)
            // Metadata must stay inside this backup and remain small enough for a bounded read.
            guard url.resolvingSymlinksInPath().path == url.path,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 4_194_304,
                  let data = try? Data(contentsOf: url),
                  let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
            else { return [:] }
            return value as? [String: Any] ?? [:]
        }
        func text(_ value: Any?) -> String? {
            guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return String(value.prefix(200))
        }
        let info = plist("Info.plist"), status = plist("Status.plist")
        return BackupMetadata(deviceName: text(info["Device Name"]),
                              deviceID: text(info["Target Identifier"]) ?? text(info["Unique Identifier"]),
                              date: status["Date"] as? Date ?? info["Last Backup Date"] as? Date,
                              completed: (status["SnapshotState"] as? String) == "finished")
    }

    var detail: String {
        let dateText = date.map { $0.formatted(date: .numeric, time: .shortened) } ?? "日期無法辨識"
        let state = completed ? "完成狀態已記錄（未驗證可還原）" : "完成狀態不明，請手動確認"
        return "備份日期 \(dateText) · \(state)" + (isLatest ? " · 此裝置最新已辨識備份" : "")
    }
}

func markLatestBackups(_ candidates: [Candidate]) -> [Candidate] {
    // Only completed, dated backups with an explicit device ID can share a group.
    let dates = candidates.reduce(into: [String: Date]()) { result, item in
        guard item.category == .backups, let backup = item.backup, backup.completed,
              let id = backup.deviceID, let date = backup.date else { return }
        result[id] = max(result[id] ?? .distantPast, date)
    }
    return candidates.map { original in
        var item = original
        if let backup = item.backup {
            item.backup?.isLatest = backup.completed && backup.deviceID.flatMap { dates[$0] }.map { $0 == backup.date } == true
        }
        return item
    }
}
