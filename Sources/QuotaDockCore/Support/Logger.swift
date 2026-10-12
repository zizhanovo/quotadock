import Foundation

// MARK: - 日志（stdout + fflush，launchd 重定向到 /tmp/quotadock.out.log）

public enum Log {
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public static func info(_ msg: String) {
        emit("ℹ️", msg)
    }

    public static func warn(_ msg: String) {
        emit("⚠️", msg)
    }

    public static func error(_ msg: String) {
        emit("❌", msg)
    }

    private static func emit(_ tag: String, _ msg: String) {
        print("[\(stampFormatter.string(from: Date()))] \(tag) \(msg)")
        fflush(stdout)
    }
}
