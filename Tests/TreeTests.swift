import Foundation

@main
struct TreeTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TreeTests-\(UUID().uuidString)").standardizedFileURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let child = root.appendingPathComponent("nested/document.txt")
        try fm.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("AAAA".utf8).write(to: child)
        let original = try FileTreeSnapshot.capture(root)
        precondition(original.bytes == 4 && original.entries.count == 3)
        print("PASS: Tree captures nested entries and logical file bytes")
        let originalRootDate = try fm.attributesOfItem(atPath: root.path)[.modificationDate] as! Date
        let originalChildDate = try fm.attributesOfItem(atPath: child.path)[.modificationDate] as! Date
        try Data("BBBB".utf8).write(to: child)
        try fm.setAttributes([.modificationDate: originalChildDate], ofItemAtPath: child.path)
        try fm.setAttributes([.modificationDate: originalRootDate], ofItemAtPath: root.path)
        let changed = try FileTreeSnapshot.capture(root)
        precondition(original != changed)
        print("PASS: Same-size child rewrite detected even when modification dates are restored")
        let extra = root.appendingPathComponent("nested/new.txt")
        try Data("new".utf8).write(to: extra)
        let added = try FileTreeSnapshot.capture(root)
        precondition(added != changed)
        print("PASS: Newly added descendant changes the snapshot")
        try fm.removeItem(at: extra)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Library"))
        let linked = try FileTreeSnapshot.capture(root)
        precondition(linked.bytes == 4 && linked.entries["link"]?.link == "/Library")
        print("PASS: External symbolic link recorded without reading its target")
        do { _ = try FileTreeSnapshot.capture(root, maximumEntries: 1); fatalError("Limit ignored") }
        catch { print("PASS: Entry limit rejects incomplete snapshots") }
        do { _ = try FileTreeSnapshot.capture(root, seconds: 0); fatalError("Timeout ignored") }
        catch { print("PASS: Deadline rejects incomplete snapshots") }

        let appURL = root.appendingPathComponent("Applications/Fixture.app")
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "org.tree.fixture", "CFBundleName": "Tree Fixture", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let support = root.appendingPathComponent("Library/Application Support/org.tree.fixture")
        try fm.createDirectory(at: support.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let doc = support.appendingPathComponent("nested/doc")
        try Data("old".utf8).write(to: doc)
        let catalog = AppCatalog(home: root)
        let app = catalog.readApp(appURL)!
        let plan = catalog.plan(app, installed: [app])
        precondition(plan.files.contains { $0.id == support.path })
        let date = try fm.attributesOfItem(atPath: support.path)[.modificationDate] as! Date
        try Data("updated".utf8).write(to: doc)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: support.path)
        let result = catalog.uninstall(plan, selected: Set(plan.files.map(\.id)))
        precondition(result.0.isEmpty && !result.1.isEmpty && fm.fileExists(atPath: appURL.path) && fm.fileExists(atPath: doc.path))
        print("PASS: Changed descendant stops uninstall before any app or data is moved")
    }
}
