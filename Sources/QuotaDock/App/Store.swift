import Foundation
import Combine
import QuotaDockCore

// MARK: - App 状态适配层：协调器结果 → 现有 UI 模型

/// UI 行模型（其他服务：Codex / Kimi / MiMo / CC）
struct ExtraService: Identifiable {
    let id: String           // 稳定身份 key（ForEach 与合并主键）
    let name: String
    let value: String        // 右侧主数值（有进度条时放数据时间）
    let detail: String       // 第二行说明
    let usedPercent: Int?    // 状态色依据；nil=无用量概念
    var fiveBar: LimitEntry? = nil   // 有值时渲染 5h/周 双进度条（Claude Code VPS）
    var weekBar: LimitEntry? = nil
    var stale: Bool = false          // 数据停更超 24h，⚠ 标橙
}

/// 智谱 key 行模型
struct KeyQuota: Identifiable {
    var id: String { identityKey }
    let identityKey: String   // 稳定身份（合并主键，替代数组索引）
    let name: String          // 短名，如 "周卡"
    let keyTail: String       // key 后4位
    var quota: QuotaData?
    var error: String?
    var lastGoodAt: Date?     // 最近成功时间（摘要/缓存标注）
}

/// 设置区"来源状态"行
struct SourceLine: Identifiable {
    let id: String
    let name: String
    let state: String       // 正常 / 缓存 HH:mm / 凭据失效 / 未配置 / 停用
    let ok: Bool            // true=绿点 false=灰/橙点
}

/// 面板状态：把 RefreshCoordinator 的 outcomes 映射为现有视图直接消费的行，
/// 并持有显示偏好（勾选/剩余%/自动切换/吸边）。autoPing 在这层触发（依赖刷新结果）。
@MainActor
final class Store: ObservableObject {
    let coordinator: RefreshCoordinator
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTimer: Timer?

    @Published var keyQuotas: [KeyQuota] = []
    @Published var extras: [ExtraService] = []
    @Published var lastUpdate: Date?
    @Published var lastError: String?
    @Published var selectedTails: [String]? {        // nil=未配置过(默认全显示)
        didSet { UserDefaults.standard.set(selectedTails, forKey: "displayKeys") }
    }
    @Published var autoOnly: Bool {                  // 只显示最紧张的那个
        didSet { UserDefaults.standard.set(autoOnly, forKey: "autoOnly") }
    }
    @Published var showRemaining: Bool {
        didSet { UserDefaults.standard.set(showRemaining, forKey: "showRemaining") }
    }
    @Published var stripMode = false                 // 收起态=吸边细条
    @Published var stripEdge: DockEdge

    init(sources: [QuotaSource]? = nil,
         config: ConfigurationStore = .shared,
         cache: CacheStore = CacheStore(),
         skipList: SkipListStore = .shared) {
        selectedTails = UserDefaults.standard.array(forKey: "displayKeys") as? [String]
        autoOnly = UserDefaults.standard.bool(forKey: "autoOnly")
        showRemaining = UserDefaults.standard.bool(forKey: "showRemaining")
        stripEdge = UserDefaults.standard.string(forKey: "stripEdge").flatMap(DockEdge.init(rawValue:)) ?? .right

        coordinator = RefreshCoordinator(
            sources: sources ?? [ZhipuSource(skipList: skipList), CodexSource(), KimiSource(),
                                 MiMoSource(), ClaudeCodeSource()],
            configProvider: { config.currentSnapshot() },
            cache: cache,
            skipList: skipList
        )
        coordinator.seedFromCache()
        rebuildRows(from: coordinator.outcomes)

        // 刷新结果 → 行模型
        coordinator.$outcomes
            .receive(on: RunLoop.main)
            .sink { [weak self] outcomes in
                self?.rebuildRows(from: outcomes)
            }
            .store(in: &cancellables)

        // 配置热加载：下一个安全刷新边界应用（在飞请求持有旧配置快照，不受影响）
        config.onChange = { [weak self] _ in
            self?.startRefreshTimer(config: config)
            self?.coordinator.refreshAll(force: false)
        }
        config.startWatching()
    }

    // MARK: 行模型映射

    private func rebuildRows(from outcomes: [String: SourceOutcome]) {
        var keys: [KeyQuota] = []
        var services: [ExtraService] = []
        var latest: Date?

        for outcome in outcomes.values.sorted(by: { $0.identity.key < $1.identity.key }) {
            if outcome.status == .success, let at = outcome.lastGoodAt {
                latest = max(latest ?? .distantPast, at) as Date?
            }
            switch outcome.identity.source {
            case .zhipu:
                keys.append(Self.keyRow(for: outcome))
            case .codex, .kimi, .mimo, .claudeCode:
                services.append(Self.extraRow(for: outcome))
            }
        }
        keyQuotas = keys
        extras = services.sorted { ($0.usedPercent ?? -1) > ($1.usedPercent ?? -1) }
        lastUpdate = latest

        if keys.isEmpty, services.isEmpty {
            lastError = L("未发现任何额度来源，检查各服务配置", "no quota sources found; check service configs")
        } else {
            lastError = nil
        }
        logRowsIfChanged(keys: keys, services: services)
        scheduleAutoPing()
    }

    /// 每轮一行摘要日志（launchd 排查用）；内容没变不重复打
    private var lastLoggedSignature = ""

    private func logRowsIfChanged(keys: [KeyQuota], services: [ExtraService]) {
        let keyPart = keys.map { kq in
            let pct = kq.quota.map { "\($0.maxPercentage)%" } ?? (kq.error.map { _ in "err" } ?? "-")
            return "\(kq.name)(…\(kq.keyTail))=\(pct)"
        }.joined(separator: " ")
        let svcPart = services.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
        let signature = keyPart + " | " + svcPart
        guard signature != lastLoggedSignature else { return }
        lastLoggedSignature = signature
        Log.info("面板: \(signature.isEmpty ? "（无数据）" : signature)")
    }

    // MARK: 摘要（响应显示勾选/自动切换的即时变化，故为计算属性）

    /// 全部可见行里最紧张的一项；无有效数据时为 nil（摘要卡转引导态）
    var summary: SummaryInfo? {
        var best: (name: String, used: Int, reset: Double?, at: Date?)?
        for kq in visibleKeys {
            guard let q = kq.quota else { continue }
            let used = q.maxPercentage
            if best == nil || used > best!.used {
                let reset = [q.fiveHour?.nextResetTime, q.weekly?.nextResetTime]
                    .compactMap { $0 }.filter { $0 > Date().timeIntervalSince1970 * 1000 }.min()
                best = (kq.name, used, reset, kq.lastGoodAt)
            }
        }
        for s in extras {
            guard let used = s.usedPercent else { continue }
            if best == nil || used > best!.used {
                let reset = [s.fiveBar?.nextResetTime, s.weekBar?.nextResetTime]
                    .compactMap { $0 }.filter { $0 > Date().timeIntervalSince1970 * 1000 }.min()
                best = (s.name, used, reset, nil)
            }
        }
        guard let b = best else { return nil }
        return SummaryInfo(name: b.name, usedPercent: b.used, nearestResetMs: b.reset, observedAt: b.at)
    }

    /// 设置区"来源状态"：每个数据源一颗状态点
    var sourceLines: [SourceLine] {
        let cfg = ConfigurationStore.shared.currentSnapshot()
        let outcomes = coordinator.outcomes
        var lines: [SourceLine] = []
        let names: [SourceID: String] = [.zhipu: "智谱", .codex: "Codex", .kimi: "Kimi",
                                         .mimo: "MiMo", .claudeCode: "Claude Code"]
        for src in SourceID.allCases {
            let enabled = src == .zhipu ? true : (cfg[src.rawValue]?.bool("enabled", true) ?? true)
            let relevant = outcomes.values.filter { $0.identity.source == src }
            if !enabled {
                lines.append(SourceLine(id: src.rawValue, name: names[src] ?? src.rawValue, state: L("停用", "off"), ok: false))
            } else if relevant.isEmpty {
                lines.append(SourceLine(id: src.rawValue, name: names[src] ?? src.rawValue, state: L("未配置", "not set"), ok: false))
            } else if relevant.allSatisfy({ $0.status == .success }) {
                lines.append(SourceLine(id: src.rawValue, name: names[src] ?? src.rawValue,
                                        state: L("正常", "ok"), ok: true))
            } else if relevant.contains(where: { if case .unauthorized = $0.status { return true }; return false }) {
                lines.append(SourceLine(id: src.rawValue, name: names[src] ?? src.rawValue,
                                        state: L("凭据失效", "invalid"), ok: false))
            } else {
                let at = relevant.compactMap { $0.lastGoodAt }.max()
                let when = at.map { Fmt.bjTime.string(from: $0) } ?? "--"
                lines.append(SourceLine(id: src.rawValue, name: names[src] ?? src.rawValue,
                                        state: L("缓存 ", "cached ") + when, ok: false))
            }
        }
        return lines
    }

    /// 智谱 outcome → KeyQuota（快照含 5h/周 LimitEntry 与 level）
    static func keyRow(for outcome: SourceOutcome) -> KeyQuota {
        let tail = outcome.identity.shortLabel ?? String(outcome.identity.key.suffix(4))
        var quota: QuotaData?
        var error: String?
        if let snap = outcome.snapshot {
            quota = QuotaData(fiveHour: snap.fiveHour, weekly: snap.weekly, tools: nil,
                              level: snap.meta["level"] ?? "-")
        }
        if outcome.status != .success {
            error = FetchClassifier.displayHint(for: outcome.status,
                                                lastGoodAt: outcome.lastGoodAt,
                                                language: ConfigurationStore.shared.language)
        }
        return KeyQuota(identityKey: outcome.identity.key, name: outcome.displayName,
                        keyTail: tail, quota: quota, error: error, lastGoodAt: outcome.lastGoodAt)
    }

    /// 其他服务 outcome → ExtraService
    static func extraRow(for outcome: SourceOutcome) -> ExtraService {
        let snap = outcome.snapshot
        let hasData = snap != nil
        // 数据时间列（MiMo/CC 的时间型 value）
        let when: String
        if let at = outcome.lastGoodAt {
            let f = Date().timeIntervalSince(at) > FreshnessPolicy.staleAfter ? Fmt.bjDateHM : Fmt.bjTime
            let prefix = (snap?.stale ?? false) ? "⚠ " + L("停更于 ", "stale since ") : L("更新 ", "updated ")
            when = prefix + f.string(from: at)
        } else {
            when = ""
        }
        let value: String
        let detail: String
        if let pct = snap?.primaryUsedPercent {
            value = outcome.identity.source == .mimo || outcome.identity.source == .claudeCode
                ? when : "\(pct)%"
            detail = snap?.detail ?? ""
        } else if hasData {
            value = when.isEmpty ? "—" : when
            detail = snap?.detail ?? ""
        } else {
            switch outcome.status {
            case .noDataYet(let hint):
                value = "—"
                detail = hint
            default:
                value = "❌"
                detail = FetchClassifier.displayHint(for: outcome.status,
                                                     lastGoodAt: outcome.lastGoodAt,
                                                     language: ConfigurationStore.shared.language)
            }
        }
        return ExtraService(id: outcome.identity.key, name: outcome.displayName,
                            value: value, detail: detail,
                            usedPercent: snap?.primaryUsedPercent,
                            fiveBar: snap?.fiveHour, weekBar: snap?.weekly,
                            stale: snap?.stale ?? false)
    }

    // MARK: 刷新调度

    func start(config: ConfigurationStore = .shared) {
        coordinator.refreshAll()
        startRefreshTimer(config: config)
    }

    /// 定时轮询（间隔随配置热加载重建）
    func startRefreshTimer(config: ConfigurationStore = .shared) {
        let interval = config.currentSnapshot().refreshInterval
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.coordinator.refreshAll()
        }
    }

    func refreshAll(force: Bool) {
        if force {
            coordinator.refreshAll(force: true)
        } else {
            coordinator.refreshAll()
        }
    }

    // MARK: 显示偏好（v1 行为保持）

    func isSelected(_ kq: KeyQuota) -> Bool {
        guard let sel = selectedTails else { return true }
        return sel.contains(kq.keyTail)
    }

    func toggleKey(_ tail: String) {
        var sel = selectedTails ?? keyQuotas.filter { isSelected($0) }.map { $0.keyTail }
        if let i = sel.firstIndex(of: tail) { sel.remove(at: i) } else { sel.append(tail) }
        selectedTails = sel
    }

    /// 吸边条/列表要显示的 key（按勾选过滤；autoOnly 时只留用量最高的；默认按紧张度降序）
    var visibleKeys: [KeyQuota] {
        let visible = keyQuotas.filter { isSelected($0) }
        let sorted = visible.sorted { ($0.quota?.maxPercentage ?? -1) > ($1.quota?.maxPercentage ?? -1) }
        guard autoOnly, !sorted.isEmpty else { return sorted }
        return [sorted[0]]
    }

    // MARK: 个人套餐自动敲窗（5h 用量≈0 时跑配置命令起算窗口；默认关闭）

    private var autoPingInFlight = false
    private var lastAutoPing: Date?

    private func scheduleAutoPing() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            guard let ap = ConfigurationStore.shared.currentSnapshot()["autoPing"],
                  ap.bool("enabled", false) else { return }
            guard let personal = self.keyQuotas.first(where: { $0.identityKey.hasPrefix("zp:individual") }),
                  let q = personal.quota, let five = q.fiveHour else { return }
            guard five.percentage <= 1 else { return }
            if let last = self.lastAutoPing, Date().timeIntervalSince(last) < 600 { return }
            if self.autoPingInFlight { return }
            let cmd = ap.str("command", "/opt/homebrew/bin/glm-ping")
            guard FileManager.default.isExecutableFile(atPath: cmd) else { return }
            self.autoPingInFlight = true
            self.lastAutoPing = Date()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cmd)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            DispatchQueue.global().async {
                defer { DispatchQueue.main.async { self.autoPingInFlight = false } }
                do { try proc.run() } catch {
                    Log.warn("auto-ping 启动失败: \(error.localizedDescription)")
                    return
                }
                proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Log.info("auto-ping: \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))")
            }
        }
    }
}
