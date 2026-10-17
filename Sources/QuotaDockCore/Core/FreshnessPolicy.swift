import Foundation

// MARK: - 新鲜度策略

/// 数据时间分级：驱动"数据是不是新鲜"的展示与停更警告。
public enum Freshness: Equatable {
    case fresh(Date)     // 本轮刷新成功
    case cached(Date)    // 临时故障间隙，展示最近成功值
    case stale(Date)     // 停更超时（默认 24h），标 ⚠
    case noneYet         // 从未有数据

    public var observedAt: Date? {
        switch self {
        case .fresh(let d), .cached(let d), .stale(let d): return d
        case .noneYet: return nil
        }
    }
}

public struct FreshnessPolicy {
    public static let staleAfter: TimeInterval = 86400  // 24h

    /// Claude Code 用量快照的停更线：缓存只在有人跑 /usage 或探针时才变，24h 才警告会让
    /// 7 小时前的旧数字看起来像新的。
    public static let usageSnapshotStaleAfter: TimeInterval = 3600

    public static func classify(lastGoodAt: Date?, now: Date = Date()) -> Freshness {
        guard let at = lastGoodAt else { return .noneYet }
        return now.timeIntervalSince(at) > staleAfter ? .stale(at) : .cached(at)
    }

    /// 剩余/已用切换只改数字，不改颜色阈值与排序（同一颜色不随模式反转语义）
    public static func percent(forDisplay used: Int, showRemaining: Bool) -> Int {
        showRemaining ? 100 - used : used
    }
}
