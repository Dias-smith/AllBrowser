import Foundation

/// Debug logging for local-player / stream resolution.
/// Filter Xcode console with: `[Stream]`
public enum StreamLog {
    public static func info(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        print("[Stream] \(message) (\(file):\(line))")
    }

    public static func error(_ message: String, error: Error? = nil, file: StaticString = #fileID, line: UInt = #line) {
        if let error {
            print("[Stream][ERR] \(message) | \(error.localizedDescription) (\(file):\(line))")
        } else {
            print("[Stream][ERR] \(message) (\(file):\(line))")
        }
    }

    public static func truncate(_ value: String?, limit: Int = 160) -> String {
        guard let value, !value.isEmpty else { return "(nil)" }
        if value.count <= limit { return value }
        return String(value.prefix(limit)) + "…"
    }
}
