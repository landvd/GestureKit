import Foundation

/// Tiny file logger so the app can be diagnosed without a console.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GestureKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gesturekit.log")
    }()

    private static let queue = DispatchQueue(label: "gesturekit.log", qos: .utility)
    private static let formatter = ISO8601DateFormatter()
    private static var handle: FileHandle?

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
        }
    }

    /// Wait for pending lines (before exit in command-line modes).
    static func flush() { queue.sync {} }
}
