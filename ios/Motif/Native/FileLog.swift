import Foundation
import OSLog

/// Append-only file logger. iOS's unified `Logger` is great in Console.app
/// but inaccessible from a USB-attached Mac without entitlements, so the
/// connect path also dups its key events into `Documents/motif.log` —
/// which we can pull with `xcrun devicectl device copy from`.
enum FileLog {
    private static let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                             in: .userDomainMask).first!
        return docs.appendingPathComponent("motif.log")
    }()

    private static let osLog = Logger(subsystem: "io.allsunday.motif",
                                      category: "FileLog")
    private static let queue = DispatchQueue(label: "io.allsunday.motif.filelog",
                                             qos: .utility)
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Truncate on first call (per process launch). Subsequent writes append.
    private static let truncateOnce: Void = {
        try? Data().write(to: url)
        return ()
    }()

    static func note(_ category: String, _ message: String) {
        _ = truncateOnce
        osLog.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        let line = "\(fmt.string(from: Date())) \(category) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            if let fh = try? FileHandle(forWritingTo: url) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            } else {
                // First write — file may not exist yet after truncate.
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
