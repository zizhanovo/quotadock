import Foundation

// MARK: - 数据源契约

/// 取消令牌：协调器在手动刷新开启新代次时取消旧任务；数据源在长重试梯子中检查它。
public final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    /// 配合重试梯子使用：取消时提前退出，返回 true
    public func checkCancelled() async -> Bool {
        if isCancelled { return true }
        try? await Task.sleep(nanoseconds: 1)  // 让出执行权，顺带接收 Task 取消
        return isCancelled || Task.isCancelled
    }
}

/// 一次抓取的全部输入。数据源只从这里拿配置，不访问全局单例。
public struct SourceConfiguration {
    public let identity: SourceIdentity
    public let app: AppConfiguration
    /// 本身份的刷新间隔（节流与展示用）
    public let refreshInterval: TimeInterval
    /// 单次请求超时
    public let timeout: TimeInterval

    public init(identity: SourceIdentity, app: AppConfiguration,
                refreshInterval: TimeInterval, timeout: TimeInterval) {
        self.identity = identity
        self.app = app
        self.refreshInterval = refreshInterval
        self.timeout = timeout
    }
}

/// 数据源协议：读取凭据、发请求或读本地快照、解析并返回领域模型。
/// 不许碰 SwiftUI 状态、窗口位置或全局配置。
public protocol QuotaSource {
    var id: SourceID { get }

    /// 当前配置下可刷新的身份列表（智谱=各 key，CC=各服务器，其余=本体）。
    /// includeSkipped=true 时把 skip 名单里的身份也列出（手动强制刷新的重探路径）。
    func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity]

    func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult
}
