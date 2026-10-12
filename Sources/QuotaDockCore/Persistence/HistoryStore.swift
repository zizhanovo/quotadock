import Foundation

// MARK: - 用量历史：趋势图与大屏仪表盘的数据面
//
// 每次刷新成功按身份追加一个采样点（primary/5h/周 百分比），保留 7 天。
// 与 CacheStore 同一安全约束：只含百分比数字，无任何凭据/明细。

public struct HistoryPoint: Codable, Equatable {
    public let t: TimeInterval      // epoch 秒
    public let u: Int?              // 主值（primary 已用%）
    public let f: Int?              // 5h 窗口已用%
    public let w: Int?              // 周窗口已用%

    public init(t: TimeInterval, u: Int?, f: Int?, w: Int?) {
        self.t = t
        self.u = u
        self.f = f
        self.w = w
    }
}

public struct HistorySeries: Codable {
    public let source: String
    public var displayName: String
    public var points: [HistoryPoint]
}

public final class HistoryStore {
    public static let retention: TimeInterval = 7 * 86400
    private static let maxPointsPerSeries = 3000
    public static let schemaVersion = 1

    public let url: URL
    private let lock = NSLock()
    private var series: [String: HistorySeries]
    private let now: () -> Date

    public init(url: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/quotadock/history.json")
        self.now = now
        if let data = try? Data(contentsOf: self.url),
           let obj = try? JSONDecoder().decode([String: HistorySeries].self, from: data) {
            series = obj
        } else {
            series = [:]
        }
    }

    /// 追加一个采样点并异步剪枝落盘（超过保留期/点数上限的丢弃）
    public func append(identityKey: String, source: SourceID,
                       displayName: String, point: HistoryPoint) {
        lock.lock(); defer { lock.unlock() }
        var s = series[identityKey] ?? HistorySeries(source: source.rawValue,
                                                     displayName: displayName, points: [])
        s.displayName = displayName
        s.points.append(point)
        let cutoff = now().timeIntervalSince1970 - Self.retention
        s.points.removeAll { $0.t < cutoff }
        if s.points.count > Self.maxPointsPerSeries {
            s.points.removeFirst(s.points.count - Self.maxPointsPerSeries)
        }
        series[identityKey] = s
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(series) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func points(identityKey: String) -> [HistoryPoint] {
        lock.lock(); defer { lock.unlock() }
        return series[identityKey]?.points ?? []
    }

    public func readAll() -> [String: HistorySeries] {
        lock.lock(); defer { lock.unlock() }
        return series
    }
}
