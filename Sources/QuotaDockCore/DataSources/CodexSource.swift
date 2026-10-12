import Foundation

// MARK: - Codex（ChatGPT OAuth）数据源

/// 用 ~/.codex/auth.json 的 OAuth token 查官方用量接口。
/// chatgpt.com 的出口 IP 会被 Cloudflare 间歇性 403（VPN 出口轮换导致），直连/代理交替重试；
/// 全失败时协调器保留最近成功值（缓存时间标注）。401/403 视为凭据过期（跑 codex login 可恢复），
/// 不写 skip。
public struct CodexSource: QuotaSource {
    public let id = SourceID.codex

    public init() {}

    public func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity] {
        [SourceIdentity(source: .codex, key: "codex:default", displayName: "Codex")]
    }

    public func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
        let identity = configuration.identity
        let authPath = configuration.app["codex"]?.path("authPath", "~/.codex/auth.json") ?? ""
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let tok = tokens["access_token"] as? String,
              let acct = tokens["account_id"] as? String else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("缺少 ~/.codex/auth.json，先跑一次 codex 登录", "missing ~/.codex/auth.json; run codex login first")))
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/usage")!)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue(acct, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.timeoutInterval = configuration.timeout

        let ccfg = configuration.app["codex"]
        let proxyHost = ccfg?.str("proxyHost", "127.0.0.1") ?? "127.0.0.1"
        let proxyPort = ccfg?.int("proxyPort", 6152) ?? 6152
        let retryGap = ccfg?.dbl("retryIntervalSeconds", 15) ?? 15
        let n = max(1, ccfg?.int("retries", 4) ?? 4)
        let sequence: [Bool] = (0..<n).map { proxyPort > 0 && $0 % 2 == 1 }   // 直连/代理交替

        var lastStatus = 0
        for (i, viaProxy) in sequence.enumerated() {
            if await cancellation.checkCancelled() {
                return SourceResult(identity: identity, snapshot: nil, status: .networkError("cancelled"))
            }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = viaProxy
                ? ["HTTPSEnable": 1, "HTTPSProxy": proxyHost, "HTTPSPort": proxyPort,
                   "HTTPEnable": 1, "HTTPProxy": proxyHost, "HTTPPort": proxyPort]
                : [:]
            cfg.timeoutIntervalForRequest = configuration.timeout
            let session = URLSession(configuration: cfg)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (body, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lastStatus = status
                if status == 200 {
                    return Self.parse(body: body, identity: identity)
                }
                // 401/403：token 过期（跑 codex login 可恢复），保留缓存不写 skip
                if status == 401 || status == 403 {
                    return SourceResult(identity: identity, snapshot: nil,
                                        status: .credentialStale(hint: L("OAuth token 失效，跑一次 codex 续期", "OAuth token expired; run codex to refresh")))
                }
                if status == 429 {
                    return SourceResult(identity: identity, snapshot: nil, status: .rateLimited)
                }
            } catch {
                lastStatus = 0   // 网络层失败，继续重试
            }
            if i < sequence.count - 1 {
                // 出口轮换是几十秒级，拉开重试间隔；取消可提前退出
                try? await Task.sleep(nanoseconds: UInt64(retryGap * 1_000_000_000))
            }
        }
        // 全部尝试失败：5xx/其他按服务端错误，0=纯网络错误
        return SourceResult(identity: identity, snapshot: nil,
                            status: lastStatus >= 500 ? .serverError(status: lastStatus) : .networkError("all \(n) attempts failed"))
    }

    static func parse(body: Data, identity: SourceIdentity) -> SourceResult {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .invalidPayload(diagnostic: "unparseable codex usage"))
        }
        let plan = (obj["plan_type"] as? String ?? "").capitalized
        var pct: Int?
        var reset = ""
        if let rl = obj["rate_limit"] as? [String: Any], let pw = rl["primary_window"] as? [String: Any] {
            pct = (pw["used_percent"] as? NSNumber)?.intValue
            if let ra = (pw["reset_at"] as? NSNumber)?.doubleValue {
                let diff = ra - Date().timeIntervalSince1970
                if diff > 0 {
                    if diff < 86400 { reset = L("重置 \(Int(diff) / 3600)小时\((Int(diff) % 3600) / 60)分后", "resets in \(Int(diff) / 3600)h\((Int(diff) % 3600) / 60)m") }
                    else { reset = L("重置 \(Int(diff) / 86400)天\((Int(diff) % 86400) / 3600)小时后", "resets in \(Int(diff) / 86400)d\((Int(diff) % 86400) / 3600)h") }
                }
            }
        }
        var detail = L("周窗口", "Weekly") + "\(reset.isEmpty ? "" : " · " + reset)"
        if let credits = (obj["credits"] as? [String: Any])?["balance"] as? String, credits != "0" {
            detail += " · credits \(credits)"
        }
        let name = plan.isEmpty ? "Codex" : "Codex \(plan)"
        let snapshot = QuotaSnapshot(primaryUsedPercent: pct, fiveHour: nil, weekly: nil,
                                     detail: detail, stale: false,
                                     meta: plan.isEmpty ? [:] : ["plan": plan])
        return SourceResult(identity: identity, snapshot: snapshot, status: .success,
                            displayNameOverride: plan.isEmpty ? nil : name)
    }
}
