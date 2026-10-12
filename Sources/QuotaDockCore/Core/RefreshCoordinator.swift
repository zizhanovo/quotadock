import Foundation
import Combine

// MARK: - 刷新协调器：并发、代次、单飞、节流、结果合并

/// 合并规则（v2 设计规格 §刷新与错误状态）：
/// - success → 更新快照 + observedAt，写缓存
/// - 网络/429/5xx/解析失败/凭据过期 → 保留最近成功值，只更新状态，**绝不写 skip**
/// - unauthorized(confirmed) → 清除数字 + 写 skip
/// - noDataYet → 引导动作，不动已有数据
///
/// 代次：手动强制刷新 bump generation 并取消所有在飞任务；旧代次的结果直接丢弃，
/// 不会覆盖新代次。同一身份同一时间最多一个请求（单飞）。
@MainActor
public final class RefreshCoordinator: ObservableObject {
    @Published public private(set) var outcomes: [String: SourceOutcome] = [:]
    @Published public private(set) var lastCycleAt: Date?

    private let sources: [QuotaSource]
    private let configProvider: () -> AppConfiguration
    private let cache: CacheStore
    private let history: HistoryStore?
    private let skipList: SkipListStore
    private let now: () -> Date

    private var inFlight: [String: (task: Task<Void, Never>, token: CancellationToken, source: SourceID)] = [:]
    private var lastCompleted: [String: Date] = [:]
    private var generation = 0

    public init(sources: [QuotaSource],
                configProvider: @escaping () -> AppConfiguration,
                cache: CacheStore = CacheStore(),
                history: HistoryStore? = HistoryStore(),
                skipList: SkipListStore = SkipListStore.shared,
                now: @escaping () -> Date = Date.init) {
        self.sources = sources
        self.configProvider = configProvider
        self.cache = cache
        self.history = history
        self.skipList = skipList
        self.now = now
    }

    /// 启动时恢复上次会话的最近可信值（UI 标注缓存时间）
    public func seedFromCache() {
        for (key, outcome) in cache.restoreOutcomes(now: now()) {
            if outcomes[key] == nil { outcomes[key] = outcome }
        }
    }

    /// 一轮刷新。force=true（手动刷新）：取消在飞任务、bump 代次、无视节流、重探 skip 身份。
    public func refreshAll(force: Bool = false) {
        refresh(sourceIDs: nil, force: force)
    }

    /// 单源强制刷新（设置页"验证"按钮）：只作用指定数据源。
    public func refresh(sourceIDs: [SourceID]?, force: Bool = false) {
        if force {
            generation += 1
            for (key, flight) in inFlight {
                // 单源刷新只取消该源的在飞任务
                if sourceIDs == nil || sourceIDs!.contains(flight.source) {
                    flight.task.cancel()
                    flight.token.cancel()
                    inFlight[key] = nil
                }
            }
        }
        let cfg = configProvider()
        let currentGen = generation
        for source in sources {
            if let sourceIDs, !sourceIDs.contains(source.id) { continue }
            let enabled: Bool
            if source.id == .zhipu {
                enabled = true
            } else {
                enabled = cfg[source.id.rawValue]?.bool("enabled", true) ?? true
            }
            guard enabled else {
                pruneOutcomes(sourceID: source.id, keeping: [])
                continue
            }
            let identities = source.identities(configuration: cfg, includeSkipped: force)
            pruneOutcomes(sourceID: source.id, keeping: identities.map { $0.key })
            let interval = cfg.interval(for: source.id)
            for identity in identities where force || isDue(identity, interval: interval) {
                start(identity: identity, source: source, cfg: cfg, generation: currentGen, force: force)
            }
        }
        lastCycleAt = now()
    }

    /// 停用/消失的身份从结果表移除（行不残留）
    private func pruneOutcomes(sourceID: SourceID, keeping keys: [String]) {
        let keep = Set(keys)
        for (key, outcome) in outcomes where outcome.identity.source == sourceID && !keep.contains(key) {
            outcomes[key] = nil
        }
    }

    private func isDue(_ identity: SourceIdentity, interval: TimeInterval) -> Bool {
        guard let last = lastCompleted[identity.key] else { return true }
        return now().timeIntervalSince(last) >= max(30, interval)
    }

    private func start(identity: SourceIdentity, source: QuotaSource,
                       cfg: AppConfiguration, generation: Int, force: Bool) {
        // 单飞：同身份在飞时，force 取旧任务开新代次；普通轮次直接跳过
        if let existing = inFlight[identity.key] {
            guard force else { return }
            existing.token.cancel()
            existing.task.cancel()
            inFlight[identity.key] = nil
        }
        let token = CancellationToken()
        let interval = cfg.interval(for: source.id)
        let config = SourceConfiguration(
            identity: identity,
            app: cfg,
            refreshInterval: interval,
            timeout: source.id == .zhipu ? 15 : 15
        )
        let skipped = skipList.isSkipped(identity)
        let task = Task { [weak self] in
            let result = await source.fetch(configuration: config, cancellation: token)
            self?.finish(result: result, generation: generation, wasSkipped: skipped)
        }
        inFlight[identity.key] = (task, token, source.id)
    }

    private func finish(result: SourceResult, generation: Int, wasSkipped: Bool) {
        inFlight[result.identity.key] = nil
        lastCompleted[result.identity.key] = now()
        // 旧代次的迟到结果不得覆盖新代次
        guard generation == self.generation else { return }
        apply(result, wasSkipped: wasSkipped)
    }

    /// 合并表
    private func apply(_ result: SourceResult, wasSkipped: Bool) {
        let key = result.identity.key
        var outcome = outcomes[key] ?? SourceOutcome(identity: result.identity)
        if let name = result.displayNameOverride { outcome.displayName = name }

        switch result.status {
        case .success:
            if let snapshot = result.snapshot {
                outcome.snapshot = snapshot
                outcome.lastGoodAt = result.observedAt
                outcome.status = .success
                cache.write(CachedRecord(
                    source: result.identity.source.rawValue,
                    identityKey: key,
                    displayName: outcome.displayName,
                    snapshot: snapshot,
                    observedAt: result.observedAt,
                    expiresAt: result.observedAt.addingTimeInterval(FreshnessPolicy.staleAfter)
                ))
                if wasSkipped { skipList.remove(result.identity) }   // 重探成功 → 自动恢复
                // 趋势采样：成功一轮记一个点（大屏仪表盘的数据面）
                history?.append(
                    identityKey: key,
                    source: result.identity.source,
                    displayName: outcome.displayName,
                    point: HistoryPoint(
                        t: result.observedAt.timeIntervalSince1970,
                        u: snapshot.primaryUsedPercent,
                        f: snapshot.fiveHour?.percentage,
                        w: snapshot.weekly?.percentage
                    )
                )
            } else {
                outcome.status = .invalidPayload(diagnostic: "empty snapshot")
            }
        case .unauthorized(let confirmed):
            if confirmed {
                outcome.snapshot = nil
                outcome.lastGoodAt = nil
                outcome.status = result.status
                skipList.add(result.identity, reason: "credential rejected")
            } else {
                outcome.status = result.status   // 未确认的拒绝按临时故障保留旧值
            }
        case .noDataYet, .networkError, .rateLimited, .serverError,
             .invalidPayload, .credentialStale:
            // 临时故障/凭据过期/无数据：保留最近成功值与 lastGoodAt
            outcome.status = result.status
        }
        outcomes[key] = outcome
    }

    /// 调试/展示：某身份是否仍在刷新中
    public func isRefreshing(_ identityKey: String) -> Bool {
        inFlight[identityKey] != nil
    }
}
