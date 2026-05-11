import Foundation

/// Append-only file logger at Documents/debug.log. Designed to survive crashes:
/// every line is flushed and synced before returning. Pull the file via
/// `xcrun devicectl device copy from --domain appDataContainer ...`.
enum DebugLog {
    private static let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("debug.log")
    }()

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    static func reset() {
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    static func log(_ message: String, file: String = #file, line: Int = #line) {
        let stamp = timestamp()
        let fileName = (file as NSString).lastPathComponent
        let entry = "\(stamp) [\(fileName):\(line)] \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            if let data = entry.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
            try? handle.synchronize()
        }
        // Also print to stdout (useful for simulator builds)
        print(entry, terminator: "")
    }
}
