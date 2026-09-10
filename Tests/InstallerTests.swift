import Foundation

@main
struct InstallerTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("Installer-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let cleaner = Cleaner(home: home)
        func write(_ path: String) throws -> URL {
            let url = cleaner.root(.installers).appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            return url
        }
        let nested = try write("Archive/2026/setup.dmg")
        _ = try write("Archive/readme.pdf")
        _ = try write("Archive/2026/extra/too-deep.pkg")
        _ = try write("Fake.app/Contents/embedded.dmg")
        _ = try write(".hidden/private.dmg")
        _ = try write("Google Drive/offline.pkg")
        let scan = try cleaner.scan(includeSupport: false, deep: true)
        let files = scan.candidates.filter { $0.category == .installers }
        precondition(files.count == 1 && files[0].url.path == nested.path)
        print("PASS: Nested installer found without documents, packages, hidden or sync directories")
        try cleaner.validate(nested, category: .installers)
        print("PASS: Reviewed nested installer accepted by deletion-time path rules")
        do { try cleaner.validate(nested.deletingLastPathComponent(), category: .installers); fatalError("Parent accepted") }
        catch { print("PASS: Installer parent directory cannot be removed") }
        do { try cleaner.validate(cleaner.root(.installers).appendingPathComponent("Fake.app/Contents/embedded.dmg"), category: .installers); fatalError("Package child accepted") }
        catch { print("PASS: Installer inside App package rejected at deletion time") }
        let link = cleaner.root(.installers).appendingPathComponent("Linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: nested.deletingLastPathComponent())
        do { try cleaner.validate(link.appendingPathComponent("setup.dmg"), category: .installers); fatalError("Symlink accepted") }
        catch { print("PASS: Installer search cannot traverse linked folders") }
        let skipped = try cleaner.downloadInstallers(cancellation: nil, skip: [nested.deletingLastPathComponent().path], event: { _ in })
        precondition(skipped.0.isEmpty)
        print("PASS: Timed-out download subtree remains skipped on worker restart")
        let cancellation = ScanCancellation(); cancellation.cancel()
        do { _ = try cleaner.downloadInstallers(cancellation: cancellation, skip: [], event: { _ in }); fatalError("Cancellation ignored") }
        catch is CancellationError { print("PASS: Nested installer search respects cancellation") }
    }
}
