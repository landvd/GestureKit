import Foundation

/// Tiny file logger so the app can be diagnosed without a console.
/// Self-test / benchmark modes log to a temporary file: their thousands of lines used to
/// bury real usage in the user's log. The real log rolls over at `maxBytes`, keeping
/// one previous file (`gesturekit.1.log`).
enum Log {
    static let testModes = ["--selftest", "--perf", "--ui-click-test", "--tap-isolation-test"]
    static var isTestRun: Bool { CommandLine.arguments.contains { testModes.contains($0) } }
    static let maxBytes: UInt64 = 2_000_000

    static let url: URL = {
        if isTestRun {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gesturekit-test.log")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GestureKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gesturekit.log")
    }()

    static var previousURL: URL { url.deletingPathExtension().appendingPathExtension("1.log") }

    private static let queue = DispatchQueue(label: "gesturekit.log", qos: .utility)
    private static let formatter = ISO8601DateFormatter()
    private static var handle: FileHandle?
    private static var linesSinceCheck = 0

    /// Returns immediately: formatting and both writes happen on the log queue.
    /// Callers include the event-tap callback, which holds the user's mouse input
    /// until it returns (a fresh ISO8601DateFormatter per line cost ~0.1 ms there).
    static func write(_ message: String) {
        let now = Date()
        queue.async {
            let data = Data("[\(formatter.string(from: now))] \(message)\n".utf8)
            FileHandle.standardError.write(data)
            if handle == nil {
                let fm = FileManager.default
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
                handle?.seekToEndOfFile()
            }
            handle?.write(data)
            linesSinceCheck += 1
            if linesSinceCheck >= 200 { linesSinceCheck = 0; rotateIfNeeded() }
        }
    }

    /// Log queue only.
    private static func rotateIfNeeded() {
        guard let h = handle, h.offsetInFile > maxBytes else { return }
        try? h.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        try? fm.moveItem(at: url, to: previousURL)
    }

    /// Wait for pending lines (before exit in command-line modes).
    static func flush() { queue.sync {} }
}
