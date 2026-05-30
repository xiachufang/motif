import Darwin
import Foundation
import OSLog
@preconcurrency import TailscaleKit

// LogSinks for tsnet. `internal` (not `private`) because `TailscaleManager`'s
// `dial` (SilentLogger) and `start` (TsnetFileLogger) live in separate files.

/// LogSink that drops everything. (BlackholeLogger has an internal-only init,
/// so we ship our own equivalent.)
struct SilentLogger: LogSink {
    var logFileHandle: Int32? { nil }
    func log(_ message: String) {}
}

/// LogSink that routes tsnet's internal Go logs to a file under
/// Documents/logs/. We co-locate this with TalkerCommonLogging's directory
/// so SettingsView's Export Logs picks both up in one zip. stderr from the
/// simulator is unreliable to capture, so we open a real fd and read the
/// file out of band.
final class TsnetFileLogger: LogSink {
    let logFileHandle: Int32?
    private static let logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("tsnet.log", isDirectory: false)
    }()

    init() {
        // Logs/ might not exist yet if AppState's setupLogger hasn't created
        // it; createDirectory is a no-op if the path is already there.
        try? FileManager.default.createDirectory(
            at: Self.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Truncate previous run, then open for writing.
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let path = Self.logURL.path
        let fd = path.withCString { cstr in
            Darwin.open(cstr, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        self.logFileHandle = fd >= 0 ? fd : nil
        Logger(subsystem: "io.allsunday.motif", category: "tsnet")
            .notice("tsnet log file opened at \(path, privacy: .public) fd=\(fd, privacy: .public)")
    }

    func log(_ message: String) {
        Logger(subsystem: "io.allsunday.motif", category: "tsnet").notice("\(message, privacy: .public)")
    }
}
