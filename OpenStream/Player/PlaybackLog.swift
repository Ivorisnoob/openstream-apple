import os

/// Playback's own log, kept by the system (Console: subsystem com.ivor.openstream).
/// `log show --last 30m --predicate 'subsystem == "com.ivor.openstream"'` reads it back.
nonisolated enum Log {
    static let playback = Logger(subsystem: "com.ivor.openstream", category: "Playback")
}
