import Foundation
import CryptoKit

// MARK: - 智谱 Coding Plan 数据源

/// 智谱 key 的稳定身份解析：
/// - provider 配置自动发现 → "zp:provider:<providerId>#<尾号>"
/// - ZCode 个人套餐（加密凭据） → "zp:individual#<尾号>"
/// - config 手工 key → "zp:manual:<显式 id|name>#<尾号>"
/// 合并主键是身份 key 而非数组索引：重排、重命名、重复尾号不串数据。
public struct ZhipuSource: QuotaSource {
    public let id = SourceID.zhipu
    let skipList: SkipListStore

    public init(skipList: SkipListStore = .shared) {
        self.skipList = skipList
    }

    struct KeyEntry {
        let identity: SourceIdentity
        let key: String
    }

    // MARK: 身份枚举（读文件，无网络）

    func resolveEntries(configuration: AppConfiguration) -> [KeyEntry] {
        var out: [KeyEntry] = []
        var seenTails: Set<String> = []

        // 1. ZCode provider 配置自动发现（编码套餐类型 或 bigmodel-* 前缀的普通 api-key）
        let providerPath = configuration["zhipu"]?.path("providerConfigPath", "~/.zcode/v2/provider_config.json") ?? ""
        let shortNames = configuration["zhipu"]?.strDict("names") ?? [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: providerPath)),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rules = (root["config"] as? [String: Any])?["providerConfigRules"] as? [String: Any],
           let list = rules["providerRules"] as? [[String: Any]] {
            for rule in list {
                let cfg = rule["config"] as? [String: Any] ?? [:]
                let access = cfg["access"] as? [String: Any] ?? [:]
                let pid = rule["providerId"] as? String ?? ""
                let isPlan = access["type"] as? String == "zhipu-coding-plan-api-key"
                let isBigmodel = pid.hasPrefix("bigmodel-")
                guard isPlan || isBigmodel, let key = access["apiKey"] as? String else { continue }
                let name = shortNames[pid] ?? (rule["providerName"] as? String ?? pid)
                let tail = key.count >= 4 ? String(key.suffix(4)) : key
                guard !seenTails.contains(tail) else { continue }
                seenTails.insert(tail)
                out.append(KeyEntry(
                    identity: SourceIdentity(source: .zhipu, key: "zp:provider:\(pid)#\(tail)",
                                             displayName: name, shortLabel: tail),
                    key: key
                ))
            }
        }

        // 2. ZCode 个人套餐（enc:v1 AES-256-GCM 加密凭据）
        if !skipList.legacyTailList.contains("individual"),
           let ind = ZhipuSource.individualKey(configuration: configuration) {
            if !seenTails.contains(ind.tail) {
                seenTails.insert(ind.tail)
                out.append(KeyEntry(
                    identity: SourceIdentity(source: .zhipu, key: "zp:individual#\(ind.tail)",
                                             displayName: L("个人", "Personal"), shortLabel: ind.tail),
                    key: ind.key
                ))
            }
        }

        // 3. config 手工 key（zhipu.keys: [{id?, name?, key}]，显式 id 优先做身份）
        for k in configuration["zhipu"]?.list("keys") ?? [] {
            let key = k.str("key")
            guard key.count > 8 else { continue }
            let tail = String(key.suffix(4))
            guard !seenTails.contains(tail) else { continue }
            seenTails.insert(tail)
            let explicitID = k.str("id", k.str("name", L("自定义", "Custom")))
            out.append(KeyEntry(
                identity: SourceIdentity(source: .zhipu, key: "zp:manual:\(explicitID)#\(tail)",
                                         displayName: k.str("name", L("自定义", "Custom")), shortLabel: tail),
                key: key
            ))
        }
        return out
    }

    public func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity] {
        resolveEntries(configuration: configuration)
            .filter { includeSkipped || !skipList.isSkipped($0.identity) }
            .map { $0.identity }
    }

    public func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
        let identity = configuration.identity
        guard let entry = resolveEntries(configuration: configuration.app)
            .first(where: { $0.identity.key == identity.key }) else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("配置中已无此 key", "key no longer configured")))
        }
        var req = URLRequest(url: URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!)
        req.timeoutInterval = configuration.timeout
        req.setValue("Bearer " + entry.key, forHTTPHeaderField: "Authorization")

        let data: Data?
        let resp: URLResponse?
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            return SourceResult(identity: identity, snapshot: nil,
                                status: FetchClassifier.status(forNetworkError: error))
        }
        if cancellation.isCancelled {
            return SourceResult(identity: identity, snapshot: nil, status: .networkError("cancelled"))
        }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            return SourceResult(identity: identity, snapshot: nil,
                                status: FetchClassifier.status(forHTTP: http.statusCode))
        }
        guard let data = data, let quota = ZhipuParser.parse(data) else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: FetchClassifier.zhipuInvalidPayload(data))
        }
        let snapshot = QuotaSnapshot(
            primaryUsedPercent: quota.maxPercentage,
            fiveHour: quota.fiveHour,
            weekly: quota.weekly,
            detail: "",
            stale: false,
            meta: ["level": quota.level]
        )
        return SourceResult(identity: identity, snapshot: snapshot, status: .success)
    }

    // MARK: ZCode 加密凭据

    /// ~/.zcode/v2/credentials.json，enc:v1 = AES-256-GCM。
    /// 密钥 = SHA256(ZCODE_CREDENTIAL_SECRET env 或 fallback "zcode-credential-fallback:darwin:$HOME:$USER")。
    static func zcodeDecrypt(_ enc: String) -> String? {
        guard enc.hasPrefix("enc:v1:") else { return enc }
        let parts = enc.dropFirst("enc:v1:".count).components(separatedBy: ".")
        guard parts.count == 3 else { return nil }
        func b64url(_ s: String) -> Data {
            var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t) ?? Data()
        }
        guard let nonce = try? AES.GCM.Nonce(data: b64url(parts[0])) else { return nil }
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: b64url(parts[2]), tag: b64url(parts[1])) else { return nil }
        let secret = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
            ?? "zcode-credential-fallback:darwin:\(NSHomeDirectory()):\(NSUserName())"
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
        guard let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    /// 个人账号 key：credentials.json 里 individual-coding-plan 的 api-key
    static func individualKey(configuration: AppConfiguration) -> (tail: String, key: String)? {
        let credPath = configuration["zhipu"]?.path("credentialsPath", "~/.zcode/v2/credentials.json") ?? ""
        guard !credPath.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: credPath))) as? [String: String]
        else { return nil }
        for (k, v) in raw where k.contains("individual-coding-plan") && k.hasSuffix("api-key") {
            guard let key = zcodeDecrypt(v), key.count > 8 else { continue }
            return (String(key.suffix(4)), key)
        }
        return nil
    }
}
