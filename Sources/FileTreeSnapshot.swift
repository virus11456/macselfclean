import Foundation
import Darwin

struct FileTreeSnapshot: Equatable, Sendable, Codable {
    struct Entry: Equatable, Sendable, Codable {
        let inode: UInt64
        let device: Int32
        let mode: UInt16
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        let link: String?
    }
    let entries: [String: Entry]
    let bytes: Int64

    static func capture(_ root: URL, seconds: TimeInterval = 8, maximumEntries: Int = 100_000) throws -> FileTreeSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        let fm = FileManager.default
        var pending = [root], entries: [String: Entry] = [:], bytes: Int64 = 0
        func checkLimit() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline, entries.count < maximumEntries else {
                throw CleanerError.unsafe("項目太大或檢查逾時，未能建立完整明細，已略過。")
            }
        }
        func record(_ url: URL) throws -> Entry {
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0 else {
                throw CleanerError.unsafe("無法完整讀取項目，請確認權限並重新檢查。")
            }
            let type = info.st_mode & S_IFMT
            guard [S_IFREG, S_IFDIR, S_IFLNK].contains(type) else {
                throw CleanerError.unsafe("項目包含特殊檔案，無法建立可驗證的卸載明細。")
            }
            return Entry(inode: info.st_ino, device: info.st_dev, mode: info.st_mode, size: info.st_size,
                         modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                         changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec,
                         link: type == S_IFLNK ? try fm.destinationOfSymbolicLink(atPath: url.path) : nil)
        }
        while let url = pending.popLast() {
            try checkLimit()
            let entry = try record(url)
            let relative = url.path == root.path ? "" : String(url.path.dropFirst(root.path.count + 1))
            entries[relative] = entry
            if entry.mode & S_IFMT == S_IFREG { bytes += entry.size }
            if entry.mode & S_IFMT == S_IFDIR {
                // Do not follow a symlink encountered inside an App bundle or its data.
                let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                guard entries.count + pending.count + children.count <= maximumEntries else {
                    throw CleanerError.unsafe("目錄項目超過檢查上限，已略過。")
                }
                pending.append(contentsOf: children.map(\.standardizedFileURL))
            }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline, try record(root) == entries[""] else {
            throw CleanerError.changed
        }
        return FileTreeSnapshot(entries: entries, bytes: bytes)
    }
}
