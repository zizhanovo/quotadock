import Foundation

// MARK: - Magpie（Cursor 订阅额度）数据源

/// 跑 `magpie quota <provider> --json`：argv 直传不经 shell，凭据与上游请求都留在 magpie 里
/// （CLI 自带 1 分钟缓存）。每个 provider 一个身份（magpie.providers 列表，兼容旧的
/// provider 单值配置）。窗口是各家自有口径（Cursor 4 窗口 / SuperGrok 7 天 / 智谱 5h+7d+MCP）：
/// Total 类聚合口径不进条不参与主值；主值 = 最紧张的真实窗口，两条进度条放紧张度前二，
/// 窗口短名经 meta.fiveLabel/weeklyLabel 下发（UI 默认标签是 5h/周）。
public struct MagpieSource: QuotaSource {
    public let id = SourceID.magpie

    public init() {}

    /// 监控的 provider 列表：providers 数组优先，回退旧 provider 单值，默认只看 cursor
    static func providers(_ app: AppConfiguration) -> [String] {
        let sec = app["magpie"]
        let list = sec?.strList("providers") ?? []
        if !list.isEmpty { return list }
        return [sec?.str("provider", "cursor") ?? "cursor"]
    }

    /// provider → 行显示名；与原生渠道重名的加 (magpie) 后缀避免混淆
    static func displayName(_ provider: String) -> String {
        switch provider {
        case "cursor": return "Cursor"
        case "grok": return "Grok"
        case "codex": return "Codex (magpie)"
        case "zhipu-glm": return "GLM (magpie)"
        case "kimi-code-cn": return "Kimi (magpie)"
        case "mimo-app": return "MiMo (magpie)"
        default: return provider.capitalized
        }
    }

    public func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity] {
        Self.providers(configuration).map { p in
            SourceIdentity(source: .magpie, key: "magpie:\(p)", displayName: Self.displayName(p))
        }
    }

    public func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
        let identity = configuration.identity
        let provider = String(identity.key.dropFirst("magpie:".count))
        if cancellation.isCancelled {
            return SourceResult(identity: identity, snapshot: nil, status: .networkError("cancelled"))
        }
        guard let bin = Self.resolveBin(configuration.app) else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("未找到 magpie CLI（安装后可用 magpie.binPath 指定路径）",
                                                           "magpie CLI not found (set magpie.binPath after installing)")))
        }
        let run = await Subprocess.run(bin: bin, args: ["quota", provider, "--json"], timeout: configuration.timeout)
        if cancellation.isCancelled {
            return SourceResult(identity: identity, snapshot: nil, status: .networkError("cancelled"))
        }
        guard run.code == 0 else {
            let why = run.timedOut
                ? L("magpie 查询超时", "magpie query timed out")
                : L("magpie 退出码 \(run.code)", "magpie exited \(run.code)")
            let tail = run.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return SourceResult(identity: identity, snapshot: nil,
                                status: .networkError("\(why)\(tail.isEmpty ? "" : " · " + tail.prefix(80))"))
        }
        return Self.parse(data: Data(run.out.utf8), provider: provider, identity: identity)
    }

    /// binPath 显式配置优先；否则按常见安装位寻找（launchd 的 PATH 里没有用户级目录）
    static func resolveBin(_ app: AppConfiguration) -> String? {
        let configured = app["magpie"]?.path("binPath", "") ?? ""
        let candidates = configured.isEmpty
            ? ["~/.local/bin/magpie", "/opt/homebrew/bin/magpie", "/usr/local/bin/magpie"]
            : [configured]
        for c in candidates {
            let p = (c as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    struct Window {
        let name: String
        let pct: Int
        let resetMs: Double?

        /// 进度条标签短名（MiniBar 槽位有限，窗口全名放不下）
        var shortName: String {
            switch name {
            case "Cursor Models": return "Models"
            case "Other Models": return "Other"
            case "Grok Bot": return "Grok"
            case "5 hours": return "5h"
            case "7 days": return "7d"
            case "5 hours OAuth": return "5h"
            case "7 days OAuth": return "7d"
            case "MCP · Month": return "MCP"
            default: return String(name.prefix(8))
            }
        }
    }

    /// 解析 `magpie quota --json` 的数组输出（纯函数可测）。fallbackToFirst=false 时严格
    /// 按 provider 匹配（Kimi 兜底复用本解析：magpie 里没这个账号就如实报缺，不能拿别的账号顶数）
    static func parse(data: Data, provider: String, identity: SourceIdentity,
                      now: Date = Date(), fallbackToFirst: Bool = true) -> SourceResult {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .invalidPayload(diagnostic: "unparseable magpie quota output"))
        }
        let entry = arr.first(where: { $0["provider"] as? String == provider })
            ?? (fallbackToFirst ? arr.first : nil)
        guard let entry, let windows = entry["windows"] as? [[String: Any]] else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("magpie 里还没有 \(provider) 账号",
                                                           "no \(provider) account in magpie yet")))
        }
        var wins: [Window] = []
        for w in windows {
            guard let name = w["name"] as? String,
                  let used = (w["used"] as? NSNumber)?.doubleValue else { continue }
            let resetMs = (w["resetsAt"] as? String)
                .flatMap { isoDate($0).map { $0.timeIntervalSince1970 * 1000 } }
            wins.append(Window(name: name, pct: Int(used.rounded()), resetMs: resetMs))
        }
        guard !wins.isEmpty else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .invalidPayload(diagnostic: "magpie quota output has no windows"))
        }
        let real = wins.filter { $0.name != "Total" }
        let pool = real.isEmpty ? [wins[0]] : real
        let primary = pool.map { $0.pct }.max() ?? 0
        // 紧张度前二进双条（同值按名稳定排序，避免同值时条位抖动）
        let bars = Array(pool.sorted { $0.pct == $1.pct ? $0.name < $1.name : $0.pct > $1.pct }.prefix(2))
        var meta: [String: String] = [:]
        if bars.count > 0 { meta["fiveLabel"] = bars[0].shortName }
        if bars.count > 1 { meta["weeklyLabel"] = bars[1].shortName }
        if let plan = entry["plan"] as? String, !plan.isEmpty { meta["plan"] = plan }
        let readAt = (entry["readAt"] as? String).flatMap(isoDate) ?? now
        let snapshot = QuotaSnapshot(
            primaryUsedPercent: primary,
            fiveHour: bars.count > 0 ? LimitEntry(percentage: bars[0].pct, nextResetTime: bars[0].resetMs) : nil,
            weekly: bars.count > 1 ? LimitEntry(percentage: bars[1].pct, nextResetTime: bars[1].resetMs) : nil,
            detail: "",
            stale: now.timeIntervalSince(readAt) > FreshnessPolicy.staleAfter,
            meta: meta)
        return SourceResult(identity: identity, snapshot: snapshot, status: .success, observedAt: readAt)
    }
}
