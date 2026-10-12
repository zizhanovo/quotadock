import Foundation

// MARK: - 时间格式化（时区随配置，缓存 DateFormatter）

public enum Fmt {
    private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    /// 时区从当前配置读取；同一 (format, tz) 的 formatter 缓存复用
    static func make(_ fmt: String) -> DateFormatter {
        let tz = ConfigurationStore.shared.currentSnapshot().timezoneIdentifier
        let key = "\(fmt)|\(tz)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: tz) ?? .current
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = fmt
        cache[key] = f
        return f
    }

    public static var hm: DateFormatter { make("HH:mm") }
    public static var dateWeekHM: DateFormatter { make("M月d日 EEEE HH:mm") }
    public static var bjTime: DateFormatter { make("HH:mm") }
    public static var bjDateHM: DateFormatter { make("M月d日 HH:mm") }
    public static var shortDateTime: DateFormatter { make("M/d HH:mm") }
}

/// "4小时48分后 · 20:30" 或 "6天23小时后 · 10月10日 15:22"（时区随 config）
public func countdownString(_ ms: Double?) -> String? {
    guard let ms = ms else { return nil }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let diff = date.timeIntervalSinceNow
    let f = diff < 86400 ? Fmt.bjTime : Fmt.bjDateHM
    let bj = f.string(from: date)
    guard diff > 0 else { return L("已到点 · \(bj)", "due · \(bj)") }
    if diff < 3600 {
        return L("\(Int(diff / 60) + 1)分钟后 · \(bj)", "in \(Int(diff / 60) + 1)m · \(bj)")
    } else if diff < 86400 {
        let h = Int(diff / 3600), m = Int(diff.truncatingRemainder(dividingBy: 3600) / 60) + 1
        return L("\(h)小时\(m)分后 · \(bj)", "in \(h)h\(m)m · \(bj)")
    } else {
        let d = Int(diff / 86400), h = Int(diff.truncatingRemainder(dividingBy: 86400) / 3600)
        return L("\(d)天\(h)小时后 · \(bj)", "in \(d)d\(h)h · \(bj)")
    }
}

/// 短倒计时："4小时22分" / "6天23小时" / "38分"
public func shortCountdown(_ ms: Double?) -> String {
    guard let ms = ms else { return "-" }
    let diff = Date(timeIntervalSince1970: ms / 1000).timeIntervalSinceNow
    guard diff > 0 else { return L("已到点", "due") }
    if diff < 3600 { return L("\(Int(diff / 60) + 1)分", "\(Int(diff / 60) + 1)m") }
    if diff < 86400 {
        return L("\(Int(diff / 3600))小时\(Int(diff.truncatingRemainder(dividingBy: 3600) / 60) + 1)分",
                 "\(Int(diff / 3600))h\(Int(diff.truncatingRemainder(dividingBy: 3600) / 60) + 1)m")
    }
    return L("\(Int(diff / 86400))天\(Int(diff.truncatingRemainder(dividingBy: 86400) / 3600))小时",
             "\(Int(diff / 86400))d\(Int(diff.truncatingRemainder(dividingBy: 86400) / 3600))h")
}

/// ISO8601（兼容毫秒）解析
public func isoDate(_ s: String) -> Date? {
    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso = ISO8601DateFormatter()
    return isoFrac.date(from: s) ?? iso.date(from: s)
}
