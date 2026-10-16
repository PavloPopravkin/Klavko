import os

/// Diagnostics only: never logs typed text, only events, lengths and layout IDs.
/// View with: log show --last 1h --predicate 'subsystem == "app.klavko.Klavko"'
enum Log {
    static let monitor = Logger(subsystem: "app.klavko.Klavko", category: "monitor")
    static let engine = Logger(subsystem: "app.klavko.Klavko", category: "engine")
}
