import Foundation

// MARK: - Kimi 套餐数据源

/// 首选 GET /coding/v1/usages（复数 usages）：5 小时窗口 + 周额度。
/// access_token 仅 15 分钟有效且无法本地静默续期（refresh 绑定原始设备会话）——
/// token 过期归为凭据过期（可恢复，保留最近成功值），不是确认失效，不写 skip。
/// 凭据缺失/过期时自动走 magpie 兜底（`magpie quota kimi-code-cn --json`）：
/// magpie 自管凭据，不经 kimi CLI 用 Kimi（其他设备/代理在跑）也能查到；
/// 复用 kimi:default 身份，行名保持 Kimi，不产生第二行。
public struct KimiSource: QuotaSource {
    public let id = SourceID.kimi

    /// magpie 里 Kimi 个人套餐账号的 provider 名
    static let magpieProvider = "kimi-code-cn"

    public init() {}

    public func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity] {
        [SourceIdentity(source: .kimi, key: "kimi:default", displayName: "Kimi")]
    }

    public func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
        let native = await fetchNative(configuration: configuration, cancellation: cancellation)
        switch native.status {
        case .noDataYet, .credentialStale:
            // 本地凭据缺失/过期 → magpie 兜底（用户可能根本不经 kimi CLI 用 Kimi）
            return await fetchViaMagpie(native: native, configuration: configuration,
                                        cancellation: cancellation)
        default:
            return native
        }
    }

    private func fetchNative(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
        let identity = configuration.identity
        let credPath = configuration.app["kimi"]?.path("credentialsPath", "~/.kimi-code/credentials/kimi-code.json") ?? ""
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: credPath)),
              let cred = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = cred["access_token"] as? String else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("缺少 ~/.kimi-code 凭据，先跑一次 kimi CLI", "missing kimi credentials; run kimi CLI first")))
        }
        let fresh = ((cred["expires_at"] as? NSNumber)?.doubleValue ?? 0) > Date().timeIntervalSince1970 + 30
        var req = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = configuration.timeout

        let body: Data?
        let resp: URLResponse?
        do {
            (body, resp) = try await URLSession.shared.data(for: req)
        } catch {
            return SourceResult(identity: identity, snapshot: nil,
                                status: FetchClassifier.status(forNetworkError: error))
        }
        if cancellation.isCancelled {
            return SourceResult(identity: identity, snapshot: nil, status: .networkError("cancelled"))
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 || status == 403 {
                return SourceResult(identity: identity, snapshot: nil,
                                    status: .credentialStale(hint: L("token 过期 · 跑一次 kimi CLI 自动续期", "token expired · run kimi CLI to refresh")))
            }
            return SourceResult(identity: identity, snapshot: nil,
                                status: FetchClassifier.status(forHTTP: status))
        }
        return Self.parse(body: body ?? Data(), identity: identity, tokenFresh: fresh)
    }

    /// magpie 兜底：找不到 CLI 或 magpie 自身失败时保留原生结果（兜底不该掩盖原生报错）
    private func fetchViaMagpie(native: SourceResult, configuration: SourceConfiguration,
                                cancellation: CancellationToken) async -> SourceResult {
        let identity = configuration.identity
        guard let bin = MagpieSource.resolveBin(configuration.app) else {
            Log.warn("kimi 兜底失败：未找到 magpie CLI")
            return native
        }
        let run = await Subprocess.run(bin: bin, args: ["quota", Self.magpieProvider, "--json"],
                                       timeout: configuration.timeout)
        if cancellation.isCancelled {
            return SourceResult(identity: identity, snapshot: nil, status: .networkError("cancelled"))
        }
        guard run.code == 0 else {
            Log.warn("kimi 兜底失败：\(run.timedOut ? "magpie 查询超时" : "magpie 退出码 \(run.code)")")
            return native
        }
        // 严格按 provider 匹配：magpie 里没有 kimi 账号时不能拿别的账号数据顶数
        let fallback = MagpieSource.parse(data: Data(run.out.utf8), provider: Self.magpieProvider,
                                          identity: identity, fallbackToFirst: false)
        return Self.merged(native: native, fallback: fallback, identity: identity)
    }

    /// 兜底合并（纯函数可测）：magpie 拿到数据直接用；magpie 里也没有 kimi 账号时
    /// 在原生提示后补一条 magpie 路径（"跑一次 kimi CLI"对不经 CLI 用 Kimi 的用户不是解）；
    /// magpie 执行失败则原样保留原生结果。
    static func merged(native: SourceResult, fallback: SourceResult, identity: SourceIdentity) -> SourceResult {
        if fallback.status == .success { return fallback }
        if case .noDataYet = fallback.status {
            switch native.status {
            case .noDataYet(let hint):
                return SourceResult(identity: identity, snapshot: nil,
                                    status: .noDataYet(hint: hint + Self.magpieHint))
            case .credentialStale(let hint):
                return SourceResult(identity: identity, snapshot: nil,
                                    status: .credentialStale(hint: hint + Self.magpieHint))
            default:
                break
            }
        }
        return native
    }

    private static let magpieHint = L("；或在 magpie 里配置 kimi-code-cn 账号",
                                      "; or add a kimi-code-cn account in magpie")

    static func parse(body: Data, identity: SourceIdentity, tokenFresh: Bool) -> SourceResult {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let usages = obj["usages"] as? [String: Any],
              let h5 = usages["limit_5h"] as? [String: Any],
              let w7 = usages["limit_7d"] as? [String: Any],
              let r5 = (h5["used_ratio"] as? NSNumber)?.doubleValue,
              let r7 = (w7["used_ratio"] as? NSNumber)?.doubleValue else {
            let hint = tokenFresh
                ? L("获取失败：响应无法解析", "fetch failed: unparseable response")
                : L("token 过期 · 跑一次 kimi CLI 自动续期", "token expired · run kimi CLI to refresh")
            return SourceResult(identity: identity, snapshot: nil,
                                status: tokenFresh ? .invalidPayload(diagnostic: "unparseable kimi usages")
                                                   : .credentialStale(hint: hint))
        }
        func pct(_ ratio: Double) -> Int { Int((ratio * 100).rounded()) }
        func resetMs(_ s: String) -> Double? {
            guard let d = isoDate(s) else { return nil }
            return d.timeIntervalSince1970 * 1000
        }
        let p5 = pct(r5), p7 = pct(r7)
        let top = max(p5, p7)
        let snapshot = QuotaSnapshot(
            primaryUsedPercent: top,
            fiveHour: LimitEntry(percentage: p5, nextResetTime: resetMs(h5["reset_time"] as? String ?? "")),
            weekly: LimitEntry(percentage: p7, nextResetTime: resetMs(w7["reset_time"] as? String ?? "")),
            detail: "", stale: false, meta: [:])
        return SourceResult(identity: identity, snapshot: snapshot, status: .success)
    }
}
