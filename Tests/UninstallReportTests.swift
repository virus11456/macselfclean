import Foundation

@main
struct UninstallReportTests {
    static func main() throws {
        let report = UninstallReport(appName: "Fixture", date: Date(timeIntervalSince1970: 0), selected: ["/App.app", "/prefs", "/cache"], moved: ["/App.app"], errors: ["無法移動 /cache"])
        precondition(report.moved == ["/App.app"] && report.remaining == ["/cache", "/prefs"] && report.summary.contains("未完成"))
        precondition(report.text.contains("無法移動 /cache") && report.text.contains("1970-01-01T00:00:00Z") && report.text.contains("手動還原"))
        print("PASS: Partial report retains timestamp, error, moved and unprocessed paths")
        let incomplete = UninstallReport(appName: "Fixture", selected: ["/App.app", "/prefs"], moved: ["/App.app", "/App.app", "/outside"], errors: [])
        precondition(incomplete.moved.count == 1 && incomplete.remaining == ["/prefs"] && incomplete.summary.contains("未完成"))
        print("PASS: Report cannot count duplicate or unselected paths as completed moves")
        let complete = UninstallReport(appName: "Fixture", selected: ["/App.app"], moved: ["/App.app"], errors: [])
        precondition(complete.summary.contains("卸載完成") && complete.remaining.isEmpty)
        print("PASS: Complete report requires every selected item moved and no errors")
        let suite = "MacSweep.ReportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UninstallReportStore(defaults: defaults)
        try store.save(report)
        let reopened = UninstallReportStore(defaults: UserDefaults(suiteName: suite)!)
        let restored = try reopened.load()
        precondition(restored?.text == report.text)
        print("PASS: Persisted report restores timestamp, errors and paths after store recreation")
        try store.save(complete)
        let replaced = try reopened.load()
        precondition(replaced?.text == complete.text)
        store.clear()
        let cleared = try reopened.load()
        precondition(cleared == nil)
        print("PASS: Last report replaces previous report and can be cleared")
        defaults.set("broken", forKey: store.key)
        do { _ = try store.load(); fatalError("Invalid report ignored") }
        catch { print("PASS: Invalid saved report raises a visible load error") }
        var limited = store
        limited.maximumBytes = 1
        do { try limited.save(report); fatalError("Size limit ignored") }
        catch { print("PASS: Oversized report is refused for persistence") }
    }
}
