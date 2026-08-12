import Foundation
import os

/// Debug-only diagnostic tail for background behaviour.
///
/// This was an unconditional append to `Documents/keepalive.log` — synchronous file
/// I/O on every Live Activity update, no size cap, no `#if DEBUG`, inside a
/// backed-up container. It shipped in Release and grew without bound.
///
/// It now goes to `os.Logger` (which is what the rest of the background code uses,
/// is free in Release, and is readable with Console.app / `log stream`). The file
/// copy survives only in Debug builds, where it is still the only way to read
/// device behaviour after the fact:
///
///     xcrun devicectl device copy from --domain-type appDataContainer \
///       --domain-identifier com.nightaps.aapsclientios --source Documents/keepalive.log
///
/// Prefer `Logger` directly in new code; this exists for the existing Live Activity
/// call sites.
enum DebugLog {
    #if DEBUG
    /// Past this the file is truncated and starts over. The tail is what matters
    /// when diagnosing "the app went quiet at 3 a.m.", so dropping the head is the
    /// right loss, and rewriting beats shuffling 256 KB on every line.
    static let maxBytes: UInt64 = 256 * 1024

    private static let queue = DispatchQueue(label: "com.nightaps.debuglog")
    private static let iso = ISO8601DateFormatter()
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("keepalive.log")
    }()
    #endif

    private static let logger = Logger(subsystem: "com.nightaps.aapsclientios", category: "KeepAlive")

    static func log(_ msg: String) {
        logger.debug("\(msg, privacy: .public)")
        #if DEBUG
        let line = "\(iso.string(from: Date())) \(msg)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? data.write(to: url)
                return
            }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size > maxBytes {
                try? handle.truncate(atOffset: 0)
            }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
        #endif
    }
}
