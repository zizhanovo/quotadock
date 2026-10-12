import Foundation

// MARK: - MiMo 套餐数据源（纯被动读本地缓存）

/// 纯被动：mimo-usage-sync 助手走小米 SSO 只读拉取后写缓存，QuotaDock 不碰凭据、不发请求。
/// 停更超 24h 标 ⚠（stale）。
public struct MiMoSource: QuotaSource {
    public let id = SourceID.mimo

    public init() {}

    public func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity] {
        [SourceIdentity(source: .mimo, key: "mimo:default", displayName: "MiMo")]
    }

    public func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
        let identity = configuration.identity
        let path = configuration.app["mimo"]?.path("cachePath", "~/.cache/quotadock/mimo-usage.json")
            ?? NSHomeDirectory() + "/.cache/quotadock/mimo-usage.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["ok"] as? Bool) == true,
              let usage = obj["usage"] as? [String: Any],
              let used = (usage["usedPercent"] as? NSNumber)?.doubleValue else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("跑 mimo-usage-sync 同步额度", "run mimo-usage-sync to sync")))
        }
        let remaining = (usage["remainingPercent"] as? NSNumber)?.doubleValue ?? (100 - used)
        let resetDate = usage["resetDate"] as? String ?? ""
        let plan = ((obj["subscription"] as? [String: Any])?["title"] as? String)
            ?? ((obj["subscription"] as? [String: Any])?["planCode"] as? String)
            ?? ""
        let fetchedAt = Date(timeIntervalSince1970: (obj["fetchedAt"] as? NSNumber)?.doubleValue ?? 0)
        let age = Date().timeIntervalSince(fetchedAt)
        let stale = age > FreshnessPolicy.staleAfter
        let pctUsed = Int(used.rounded())
        // 结构化：主值走 primary（单条"已用"进度条），重置日与套餐走补充位/后缀
        let detail = resetDate.isEmpty ? "" : L("重置", "reset") + " \(resetDate)"
        let snapshot = QuotaSnapshot(primaryUsedPercent: pctUsed, fiveHour: nil, weekly: nil,
                                     detail: detail, stale: stale,
                                     meta: plan.isEmpty ? [:] : ["plan": plan, "remaining": String(Int(remaining.rounded()))])
        return SourceResult(identity: identity, snapshot: snapshot, status: .success, observedAt: fetchedAt)
    }
}
