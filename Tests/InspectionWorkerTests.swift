import Foundation

@main
struct InspectionWorkerTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--leftovers-worker" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let request = try JSONDecoder().decode(LeftoversRequest.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
            if request.installed.contains(where: { $0.name == "BlockedFixture" }) { Thread.sleep(forTimeInterval: 20) }
            leftoversWorkerMain(root.path)
            return
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--inspect-worker" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let request = try JSONDecoder().decode(AppInspectionRequest.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
            if request.app.name == "BlockedFixture" { Thread.sleep(forTimeInterval: 20) }
            appInspectionWorkerMain(root.path)
            return
        }
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("Inspection-test-\(UUID().uuidString)").standardizedFileURL
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let appURL = home.appendingPathComponent("Applications/Fixture.app")
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "org.inspection.fixture", "CFBundleName": "Fixture", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let catalog = AppCatalog(home: home), app = catalog.readApp(appURL)!
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let result = try AppInspectionWorker(executable: executable).inspect(home: home, app: app, installed: [app], cancellation: ScanCancellation())
        precondition(result.files.count == 1 && result.files[0].bytes > 0 && !result.files[0].tree.entries.isEmpty)
        print("PASS: Isolated inspection worker returns complete sizes and tree snapshots")
        let blocked = InstalledApp(url: app.url, name: "BlockedFixture", bundleID: app.bundleID, version: "1", protected: false)
        let started = Date()
        do {
            _ = try AppInspectionWorker(executable: executable, timeout: 0.3).inspect(home: home, app: blocked, installed: [blocked], cancellation: ScanCancellation())
            fatalError("Timeout not enforced")
        } catch { precondition(Date().timeIntervalSince(started) < 3) }
        print("PASS: Blocked inspection process stopped within timeout")
        let cancellation = ScanCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancellation.cancel() }
        let start = Date()
        do {
            _ = try AppInspectionWorker(executable: executable).inspect(home: home, app: blocked, installed: [blocked], cancellation: cancellation)
            fatalError("Cancellation not enforced")
        } catch is CancellationError { precondition(Date().timeIntervalSince(start) < 3) }
        print("PASS: Cancellation kills blocked inspection without waiting for its filesystem work")
        precondition(fm.fileExists(atPath: appURL.path))
        print("PASS: Completed, timed-out and cancelled inspection never move the App")
        let leftoverURL = home.appendingPathComponent("Library/Preferences/org.retired.example.plist")
        try fm.createDirectory(at: leftoverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: leftoverURL)
        let leftoverResult: LeftoversResult = try AppInspectionWorker(executable: executable).run(
            request: LeftoversRequest(home: home, installed: [app]), mode: "--leftovers-worker", label: "殘留檢查", cancellation: ScanCancellation())
        precondition(leftoverResult.items.count == 1 && leftoverResult.items[0].file.bytes == 7 && leftoverResult.notes.isEmpty)
        print("PASS: Leftovers worker returns candidates and sizes without deleting them")
        let blockedRequest = LeftoversRequest(home: home, installed: [blocked])
        let timeoutStart = Date()
        do {
            let _: LeftoversResult = try AppInspectionWorker(executable: executable, timeout: 0.3).run(request: blockedRequest, mode: "--leftovers-worker", label: "殘留檢查", cancellation: ScanCancellation())
            fatalError("Timeout ignored")
        } catch { precondition(Date().timeIntervalSince(timeoutStart) < 3) }
        print("PASS: Leftovers timeout cannot be reported as a successful empty scan")
        let cancel = ScanCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancel.cancel() }
        let cancelStart = Date()
        do {
            let _: LeftoversResult = try AppInspectionWorker(executable: executable).run(request: blockedRequest, mode: "--leftovers-worker", label: "殘留檢查", cancellation: cancel)
            fatalError("Cancellation ignored")
        } catch is CancellationError { precondition(Date().timeIntervalSince(cancelStart) < 3) }
        precondition(fm.fileExists(atPath: leftoverURL.path))
        print("PASS: Cancelled leftovers worker stops promptly and preserves candidate data")
    }
}
