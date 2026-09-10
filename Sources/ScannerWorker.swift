import Foundation
import Darwin

struct ScanEvent: Codable, Sendable {
    let kind: String
    var path: String? = nil
    var candidate: Candidate? = nil
}

struct ScanRequest: Codable {
    let home: URL
    let support: Bool
    let deep: Bool
    let skip: Set<String>
}

func scanWorkerMain(_ encoded: String) {
    func emit(_ event: ScanEvent) {
        if let data = try? JSONEncoder().encode(event) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
    do {
        guard let data = Data(base64Encoded: encoded) else { return }
        let request = try JSONDecoder().decode(ScanRequest.self, from: data)
        _ = try Cleaner(home: request.home).scan(includeSupport: request.support, deep: request.deep,
                                                skip: request.skip, event: emit)
        emit(ScanEvent(kind: "finished"))
    } catch { emit(ScanEvent(kind: "note", path: error.localizedDescription)) }
}

/// Runs read-only scanning outside the UI process. A blocked filesystem call can
/// then be stopped without abandoning a live thread or blocking the main queue.
struct ScannerWorker: Sendable {
    let executable: URL
    var itemTimeout: TimeInterval = 8
    var totalTimeout: TimeInterval = 90

    func scan(home: URL, support: Bool, deep: Bool = false, cancellation: ScanCancellation,
              progress: @Sendable (String, Int) -> Void) throws -> ScanResult {
        var result = ScanResult()
        var skip: Set<String> = []
        var found: Set<String> = []
        let started = ProcessInfo.processInfo.systemUptime
        while true {
            try cancellation.check()
            let request = ScanRequest(home: home, support: support, deep: deep, skip: skip)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--scan-worker", try JSONEncoder().encode(request).base64EncodedString()]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            output.fileHandleForWriting.closeFile()
            let fd = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            defer { try? output.fileHandleForReading.close() }
            func stop() {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            var pending = Data()
            var active: String?
            var lastChange = ProcessInfo.processInfo.systemUptime
            var finished = false
            var retry = false
            while true {
                do { try cancellation.check() } catch { stop(); throw error }
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = read(fd, &bytes, bytes.count)
                if count > 0 {
                    pending.append(contentsOf: bytes.prefix(count))
                    while let end = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<end])
                        pending.removeSubrange(...end)
                        guard let event = try? JSONDecoder().decode(ScanEvent.self, from: line) else { continue }
                        switch event.kind {
                        case "checking":
                            active = event.path
                            lastChange = ProcessInfo.processInfo.systemUptime
                            progress(active ?? "", skip.count)
                        case "checked":
                            if let path = event.path { skip.insert(path) }
                            active = nil
                            lastChange = ProcessInfo.processInfo.systemUptime
                        case "candidate":
                            if let item = event.candidate, found.insert(item.id).inserted { result.candidates.append(item) }
                        case "note":
                            if let note = event.path, !result.notes.contains(note) { result.notes.append(note) }
                        case "finished": finished = true
                        default: break
                        }
                    }
                    continue
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now - started >= totalTimeout {
                    stop()
                    result.notes.append("掃描達到 \(Int(totalTimeout)) 秒上限，已停止；目前顯示部分結果。尚未完成：\(active ?? "啟動或讀取中")")
                    result.candidates = uniqueCandidates(result.candidates)
                    return result
                }
                if !process.isRunning {
                    process.waitUntilExit()
                    if !finished { result.notes.append("掃描程序提前結束（\(process.terminationStatus)），目前顯示部分結果。") }
                    break
                }
                if now - lastChange >= itemTimeout {
                    stop()
                    if let active, skip.insert(active).inserted {
                        result.notes.append("\(active)：讀取超過 \(Int(itemTimeout)) 秒，已略過；未納入清理清單。")
                        retry = true
                    } else { result.notes.append("掃描程序啟動或讀取逾時，已停止，目前顯示部分結果。") }
                    break
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            if !retry { break }
        }
        result.candidates = uniqueCandidates(result.candidates)
        return result
    }
}
