import Foundation
import AppKit
import SwiftUI
import Combine
import QuotaDockCore

// MARK: - App 状态适配层：协调器结果 → 现有 UI 模型

/// 其他服务（Codex / Kimi / MiMo / CC）的行数据——结构化，不做预格式化字符串；
/// 统一版式由 UnifiedUsageRow 渲染
struct ExtraService: Identifiable {
    let id: String           // 稳定身份 key
    let name: String
    let suffix: String       // 套餐/credits 等次级标识（小字）
    let usedPercent: Int?    // 主值：大号数字、状态色、排序
    var fiveBar: LimitEntry? = nil
    var weekBar: LimitEntry? = nil
    let resetFallback: String    // 无重置窗口时的补充（重置日期 / credits）
    let observedAt: Date?
    var stale: Bool = false      // 数据停更超 24h，⚠ 标橙
    var statusHint: String? = nil // 无数据/错误时的引导文案（有数据时挂说明行）
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
    let configStore: ConfigurationStore
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

    // 悬停展开/自动收纳的交互状态（唯一事实来源；详见 PanelRootView）
    @Published var settingsOpen = false              // 设置窗口开着时不自动收纳（配置中面板不能消失）
    var userDragging = false                         // 拖动进行中（抑制悬停展开判定，仅主线程写）
    var isHovered = false                            // 鼠标当前是否在面板上
    var pendingExpandAnchor: (edge: DockEdge, point: NSPoint)?  // 展开时面板锚定吸边条原位
    private(set) var lastAutoCollapseAt: Date?       // 防收纳后原地秒重开的抖动
    private var autoCollapseTask: Task<Void, Never>?

    /// 从吸边条展开：记录锚点（此刻窗口还是条的几何），面板贴着它出现
    func expandFromStrip() {
        if let w = NSApp.windows.first(where: { $0 is NSPanel }) {
            pendingExpandAnchor = (stripEdge, NSPoint(x: w.frame.midX, y: w.frame.midY))
        }
        withAnimation(.easeOut(duration: 0.15)) { stripMode = false }
    }

    /// 收纳回最近的边（手动 ⌄ / 自动离开超时共用）
    func collapseToStrip() {
        withAnimation(.easeOut(duration: 0.15)) {
            stripMode = true
            let e = nearestDockEdgeFromPanel()
            stripEdge = e
            UserDefaults.standard.set(e.rawValue, forKey: "stripEdge")
        }
        lastAutoCollapseAt = Date()
    }

    /// 悬停状态变化：进入取消收纳倒计时，离开重新起表
    func noteHover(_ hovering: Bool) {
        isHovered = hovering
        if hovering {
            autoCollapseTask?.cancel()
        } else {
            scheduleAutoCollapse()
        }
    }

    /// 离开 2.5s 后收纳。例外：设置窗口开着、正在拖动、鼠标又回来了。
    func scheduleAutoCollapse() {
        autoCollapseTask?.cancel()
        guard !stripMode else { return }
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !stripMode,
                  !isHovered, !settingsOpen, !userDragging else { return }
            collapseToStrip()
        }
    }

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
        configStore = config
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
        let svcPart = services.map { s in
            let pct = s.usedPercent.map { "\($0)%" } ?? (s.statusHint.map { _ in "err" } ?? "-")
            return "\(s.name)=\(pct)"
        }.joined(separator: " ")
        let signature = keyPart + " | " + svcPart
        guard signature != lastLoggedSignature else { return }
        lastLoggedSignature = signature
        Log.info("面板: \(signature.isEmpty ? "（无数据）" : signature)")
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

    /// 其他服务 outcome → 结构化行数据（统一版式由 UnifiedUsageRow 渲染）
    static func extraRow(for outcome: SourceOutcome) -> ExtraService {
        let snap = outcome.snapshot
        // 本轮异常时的行内提示：有旧值 → 挂说明行（替代重置文案）；无值 → 替代整个图表区
        var statusHint: String?
        if outcome.status != .success {
            switch outcome.status {
            case .noDataYet(let hint):
                statusHint = hint
            default:
                statusHint = FetchClassifier.displayHint(for: outcome.status,
                                                         lastGoodAt: outcome.lastGoodAt,
                                                         language: ConfigurationStore.shared.language)
            }
        }
        return ExtraService(
            id: outcome.identity.key,
            name: outcome.displayName,
            suffix: snap?.meta["plan"] ?? "",
            usedPercent: snap?.primaryUsedPercent,
            fiveBar: snap?.fiveHour,
            weekBar: snap?.weekly,
            resetFallback: snap?.detail ?? "",
            observedAt: outcome.lastGoodAt,
            stale: snap?.stale ?? false,
            statusHint: statusHint
        )
    }

    // MARK: 统一用量列表（图表化单一列表，替代旧的 智谱节+其他服务节 两截）

    /// 智谱 key + 其他服务 → 同构行，按主值降序；勾选/自动切换即时生效
    var usageRows: [UsageRowData] {
        var rows: [UsageRowData] = visibleKeys.map { kq in
            let level = kq.quota.map { $0.level } ?? "-"
            var suffix = "…\(kq.keyTail)"
            if level != "-", let q = kq.quota { _ = q; suffix += " · \(level.uppercased())" }
            return UsageRowData(
                id: kq.identityKey,
                name: kq.name,
                suffix: suffix,
                brand: "zhipu",
                primary: kq.quota?.maxPercentage,
                five: kq.quota?.fiveHour,
                weekly: kq.quota?.weekly,
                singleLabel: nil,
                resetFallback: "",
                observedAt: kq.lastGoodAt,
                stale: false,
                statusHint: kq.error
            )
        }
        rows.append(contentsOf: extras.map { s in
            UsageRowData(
                id: s.id,
                name: s.name,
                suffix: s.suffix,
                brand: BrandLogo.logoID(for: s.name),
                primary: s.usedPercent,
                five: s.fiveBar,
                weekly: s.weekBar,
                singleLabel: (s.fiveBar == nil && s.weekBar == nil) ? L("已用", "used") : nil,
                resetFallback: s.resetFallback,
                observedAt: s.observedAt,
                stale: s.stale,
                statusHint: s.statusHint
            )
        })
        return rows.sorted { ($0.primary ?? -1) > ($1.primary ?? -1) }
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

    /// 设置页"验证"：只强制刷新一个数据源
    func refreshSource(_ id: SourceID) {
        coordinator.refresh(sourceIDs: [id], force: true)
    }

    /// 配置校验结果（字段级 + 整文件级），设置页"验证"段直接展示
    var configFieldIssues: [ConfigIssue] { configStore.currentSnapshot().issues }
    var configFileIssues: [ConfigIssue] { configStore.fileIssues }

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
