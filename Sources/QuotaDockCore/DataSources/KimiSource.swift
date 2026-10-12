import Foundation

// MARK: - Kimi 套餐数据源

/// GET /coding/v1/usages（复数 usages）：5 小时窗口 + 周额度。
/// access_token 仅 15 分钟有效且无法本地静默续期（refresh 绑定原始设备会话）——
/// token 过期归为凭据过期（可恢复，保留最近成功值），不是确认失效，不写 skip。
public struct KimiSource: QuotaSource {
    public let id = SourceID.kimi

    public init() {}

    public func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity] {
        [SourceIdentity(source: .kimi, key: "kimi:default", displayName: "Kimi")]
    }

    public func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
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
