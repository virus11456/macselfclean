import Foundation

@main
struct WorkerTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 {
            let request = try JSONDecoder().decode(ScanRequest.self, from: Data(base64Encoded: CommandLine.arguments[2])!)
            let blocked = request.home.appendingPathComponent("blocked").path
            if !request.skip.contains(blocked) {
                let event = try JSONEncoder().encode(ScanEvent(kind: "checking", path: blocked))
                FileHandle.standardOutput.write(event + Data([10]))
                Thread.sleep(forTimeInterval: 20)
            }
            let done = try JSONEncoder().encode(ScanEvent(kind: "finished"))
            FileHandle.standardOutput.write(done + Data([10]))
            return
        }
        let worker = ScannerWorker(executable: URL(fileURLWithPath: CommandLine.arguments[0]), itemTimeout: 0.25, totalTimeout: 3)
        let began = Date()
        let result = try worker.scan(home: URL(fileURLWithPath: "/tmp/worker-test"), support: false,
                                     cancellation: ScanCancellation(), progress: { _, _ in })
        precondition(result.notes.contains { $0.contains("已略過") })
        precondition(Date().timeIntervalSince(began) < 3)
        print("PASS: Blocked filesystem worker killed, skipped, and restarted")
        let cancellation = ScanCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        let start = Date()
        do {
            _ = try worker.scan(home: URL(fileURLWithPath: "/tmp/worker-test"), support: false,
                                cancellation: cancellation, progress: { _, _ in })
            fatalError("Cancellation did not throw")
        } catch is CancellationError {
            precondition(Date().timeIntervalSince(start) < 2)
            print("PASS: Cancellation stops blocked worker within two seconds")
        }
    }
}
