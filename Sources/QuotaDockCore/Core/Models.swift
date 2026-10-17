import Foundation

// MARK: - 领域模型

/// 数据源标识
public enum SourceID: String, Hashable, CaseIterable {
    case zhipu
    case codex
    case kimi
    case mimo
    case claudeCode
    case magpie

    public var defaultRefreshInterval: TimeInterval {
        switch self {
        case .claudeCode: return 600   // CC 快照只在有人用时才变，默认放宽
        default: return 180
        }
    }
}

/// 一条额度窗口的原始读数（已用百分比 + 重置时间，epoch 毫秒）
public struct LimitEntry: Codable, Equatable {
    public let percentage: Int          // 已使用百分比
    public let usage: Int?              // TIME_LIMIT: 总量(次)
    public let currentValue: Int?       // TIME_LIMIT: 已用(次)
    public let nextResetTime: Double?   // epoch 毫秒

    public init(percentage: Int, usage: Int? = nil, currentValue: Int? = nil, nextResetTime: Double? = nil) {
        self.percentage = percentage
        self.usage = usage
        self.currentValue = currentValue
        self.nextResetTime = nextResetTime
    }
}

/// 智谱 quota 接口的解析结果（5h / 周 / 工具次数 / 套餐等级）
public struct QuotaData: Equatable {
    public let fiveHour: LimitEntry?
    public let weekly: LimitEntry?
    public let tools: LimitEntry?
    public let level: String

    public init(fiveHour: LimitEntry?, weekly: LimitEntry?, tools: LimitEntry?, level: String) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.tools = tools
        self.level = level
    }

    public var maxPercentage: Int {
        [fiveHour?.percentage, weekly?.percentage].compactMap { $0 }.max() ?? 0
    }
}

/// 一次成功抓取后的规范化快照：UI 与缓存共用的最小数据面。
/// detail 由数据源用当前语言生成；meta 放品牌/套餐等展示元数据（禁止放凭据）。
public struct QuotaSnapshot: Codable, Equatable {
    public var primaryUsedPercent: Int?      // 主指标（状态色与排序依据）；nil=无用量概念
    public var fiveHour: LimitEntry?         // 有 5h 窗口时渲染双进度条
    public var weekly: LimitEntry?
    public var detail: String                // 第二行说明（已本地化）
    public var stale: Bool                   // 数据停更超 24h
    public var meta: [String: String]        // zhipu level / codex plan 等

    public init(primaryUsedPercent: Int? = nil,
                fiveHour: LimitEntry? = nil,
                weekly: LimitEntry? = nil,
                detail: String = "",
                stale: Bool = false,
                meta: [String: String] = [:]) {
        self.primaryUsedPercent = primaryUsedPercent
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.detail = detail
        self.stale = stale
        self.meta = meta
    }
}

// MARK: - 错误与状态

/// 数据源结果状态。合并规则（见 RefreshCoordinator.apply）：
/// - success / *临时故障* → 保留/更新最近成功值，绝不写 skip
/// - unauthorized(confirmed: true) → 清除数字并写 skip
/// - credentialStale → 凭据过期但可恢复（如 Kimi token 15 分钟），保留最近成功值 + 引导文案
public enum SourceStatus: Equatable {
    case success
    case noDataYet(hint: String)             // 无数据时的引导动作
    case networkError(String)                // 网络抖动/超时
    case rateLimited                         // HTTP 429
    case serverError(status: Int)            // HTTP 5xx
    case unauthorized(confirmed: Bool)       // confirmed=服务端明确拒绝该身份
    case credentialStale(hint: String)       // 凭据过期需用户动作（跑一次 CLI 等）
    case invalidPayload(diagnostic: String)  // 200 但解析失败

    public var isTransient: Bool {
        switch self {
        case .networkError, .rateLimited, .serverError, .invalidPayload: return true
        case .credentialStale: return true
        default: return false
        }
    }
}

// MARK: - 身份与结果

/// 一个可独立刷新的身份：一个智谱 key / 一台 CC 服务器 / 一个服务本体。
/// key 全局稳定（配置重排、重命名、host 重复都不串数据），是缓存与 skip 的主键。
public struct SourceIdentity: Hashable {
    public let source: SourceID
    public let key: String          // 如 "zp:provider:bigmodel-api-2#J7Fk" / "cc:racknerd"
    public let displayName: String
    /// 展示用短标识（智谱 key 尾号）；无概念的服务为 nil
    public let shortLabel: String?

    public init(source: SourceID, key: String, displayName: String, shortLabel: String? = nil) {
        self.source = source
        self.key = key
        self.displayName = displayName
        self.shortLabel = shortLabel
    }
}

/// 单个身份一次抓取的产出
public struct SourceResult {
    public let identity: SourceIdentity
    public let snapshot: QuotaSnapshot?      // nil=本轮没有可用数字
    public let status: SourceStatus
    public let observedAt: Date
    public let displayNameOverride: String?  // 抓取时才得知的名字（如 Codex 套餐名）

    public init(identity: SourceIdentity,
                snapshot: QuotaSnapshot?,
                status: SourceStatus,
                observedAt: Date = Date(),
                displayNameOverride: String? = nil) {
        self.identity = identity
        self.snapshot = snapshot
        self.status = status
        self.observedAt = observedAt
        self.displayNameOverride = displayNameOverride
    }
}

/// 协调器维护的每身份长期状态（合并策略的载体）
public struct SourceOutcome {
    public let identity: SourceIdentity
    public var snapshot: QuotaSnapshot?      // 最近成功值；临时故障时保留
    public var lastGoodAt: Date?             // 最近成功时间（缓存展示标注用）
    public var status: SourceStatus
    public var displayName: String           // 含 displayNameOverride 覆盖后的当前名

    public init(identity: SourceIdentity, snapshot: QuotaSnapshot? = nil,
                lastGoodAt: Date? = nil, status: SourceStatus = .noDataYet(hint: ""),
                displayName: String? = nil) {
        self.identity = identity
        self.snapshot = snapshot
        self.lastGoodAt = lastGoodAt
        self.status = status
        self.displayName = displayName ?? identity.displayName
    }
}
