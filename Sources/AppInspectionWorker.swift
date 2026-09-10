import Foundation
import Darwin

struct AppInspectionRequest: Codable {
    let home: URL
    let app: InstalledApp
    let installed: [InstalledApp]
}

func appInspectionWorkerMain(_ directory: String) {
    let root = URL(fileURLWithPath: directory)
    do {
        let request = try JSONDecoder().decode(AppInspectionRequest.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
        let plan = AppCatalog(home: request.home).plan(request.app, installed: request.installed)
        try JSONEncoder().encode(plan).write(to: root.appendingPathComponent("result.json"), options: .atomic)
    } catch { exit(1) }
}

struct AppInspectionWorker: Sendable {
    let executable: URL
    var timeout: TimeInterval = 45

    func inspect(home: URL, app: InstalledApp, installed: [InstalledApp], cancellation: ScanCancellation) throws -> UninstallPlan {
        let request = AppInspectionRequest(home: home, app: app, installed: installed)
        let result: UninstallPlan = try run(request: request, mode: "--inspect-worker", label: "卸載明細檢查", cancellation: cancellation)
        guard result.app.id == app.id, result.app.bundleID == app.bundleID else { throw CleanerError.changed }
        return result
    }

    func run<Request: Encodable, Response: Decodable>(request: Request, mode: String, label: String,
                                                     cancellation: ScanCancellation) throws -> Response {
        try cancellation.check()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("MacSweep-inspection-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("request.json"), options: .atomic)
        let process = Process()
        process.executableURL = executable
        process.arguments = [mode, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let began = ProcessInfo.processInfo.systemUptime
        while process.isRunning {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime - began < timeout else {
                throw CleanerError.unsafe("\(label)超過時間上限，已停止讀取。沒有移動任何資料，請稍後重試。")
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        try cancellation.check()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CleanerError.unsafe("\(label)程序未完成，沒有移動資料；請重新檢查。")
        }
        let file = directory.appendingPathComponent("result.json")
        let attributes = try fm.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 128 * 1024 * 1024 else {
            throw CleanerError.unsafe("\(label)結果過大，已停止讀取。")
        }
        return try JSONDecoder().decode(Response.self, from: Data(contentsOf: file))
    }
}
