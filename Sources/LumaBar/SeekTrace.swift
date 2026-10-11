import Foundation

enum SeekTrace {
    private static let lock = NSLock()
    private static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/luma-seek-trace.log")

    static func log(_ message: String) {
        let line = String(format: "%.3f ", Date().timeIntervalSince1970) + message + "\n"
        lock.lock(); defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
