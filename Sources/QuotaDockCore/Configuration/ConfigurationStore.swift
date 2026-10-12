import Foundation

// MARK: - 配置：section 包装、校验、热加载

/// 配置节（原 Conf）。只读包装，展开 ~ 路径，提供类型化取值与默认值。
public struct ConfigSection {
    let d: [String: Any]

    public init(obj: [String: Any]) { d = obj }

    public subscript(key: String) -> ConfigSection? {
        (d[key] as? [String: Any]).map { ConfigSection(obj: $0) }
    }

    public func str(_ k: String, _ def: String = "") -> String { (d[k] as? String) ?? def }
    public func int(_ k: String, _ def: Int) -> Int { (d[k] as? NSNumber)?.intValue ?? def }
    public func dbl(_ k: String, _ def: Double) -> Double { (d[k] as? NSNumber)?.doubleValue ?? def }
    public func bool(_ k: String, _ def: Bool) -> Bool { (d[k] as? Bool) ?? def }
    public func list(_ k: String) -> [ConfigSection] { (d[k] as? [[String: Any]] ?? []).map { ConfigSection(obj: $0) } }
    /// 字符串字典（如 zhipu.names 的 providerId→显示名）
    public func strDict(_ k: String) -> [String: String] {
        guard let obj = d[k] as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }
    /// 展开 ~ 的路径配置
    public func path(_ k: String, _ def: String = "") -> String {
        let s = str(k, def)
        if s.hasPrefix("~/") { return NSHomeDirectory() + String(s.dropFirst()) }
        return s
    }
}

/// 一条配置问题：字段、原因、修复提示
public struct ConfigIssue: Equatable {
    public let field: String
    public let reason: String
    public let hint: String

    public init(_ field: String, _ reason: String, _ hint: String) {
        self.field = field
        self.reason = reason
        self.hint = hint
    }
}

/// 一份通过校验（含字段级回退）的完整配置快照。热加载时整体替换、revision+1。
public struct AppConfiguration {
    public let sanitizedRoot: [String: Any]
    public let language: String                 // "zh" | "en"
    public let timezoneIdentifier: String
    public let revision: Int
    /// 字段级问题（已回退默认值，配置整体仍可用）
    public let issues: [ConfigIssue]

    public init(root: [String: Any], revision: Int = 0) {
        let (clean, issues) = AppConfiguration.sanitize(root)
        self.sanitizedRoot = clean
        self.issues = issues
        self.language = (clean["language"] as? String) == "en" ? "en" : "zh"
        self.timezoneIdentifier = (clean["timezone"] as? String) ?? "Asia/Shanghai"
        self.revision = revision
    }

    public var root: ConfigSection { ConfigSection(obj: sanitizedRoot) }

    public subscript(key: String) -> ConfigSection? { root[key] }

    public var refreshInterval: TimeInterval {
        TimeInterval(max(30, root.int("refreshIntervalSeconds", 180)))
    }

    public func interval(for source: SourceID) -> TimeInterval {
        let def = Int(source.defaultRefreshInterval)
        let v = self[source.rawValue]?.int("refreshIntervalSeconds", def) ?? def
        return TimeInterval(max(30, v))
    }

    public var thresholds: (yellow: Int, red: Int) {
        let yellow = self["thresholds"]?.int("yellow", 60) ?? 60
        let red = self["thresholds"]?.int("red", 85) ?? 85
        return (yellow, red)
    }

    // MARK: 字段级清洗：非法值回退默认并记录 issue（配置整体保留）

    static func sanitize(_ root: [String: Any]) -> ([String: Any], [ConfigIssue]) {
        var out = root
        var found: [ConfigIssue] = []

        if let lang = out["language"] as? String, lang != "zh", lang != "en" {
            found.append(ConfigIssue("language", "language 必须是 zh 或 en，当前 \"\(lang)\"", "改回 \"zh\" 或 \"en\""))
            out["language"] = "zh"
        }
        if let tz = out["timezone"] as? String, TimeZone(identifier: tz) == nil {
            found.append(ConfigIssue("timezone", "无法识别的时区 \"\(tz)\"", "如 \"Asia/Shanghai\""))
            out["timezone"] = "Asia/Shanghai"
        }
        if let ri = out["refreshIntervalSeconds"] as? NSNumber, ri.intValue < 30 {
            found.append(ConfigIssue("refreshIntervalSeconds", "刷新间隔 \(ri.intValue)s 过短", "最小 30s，避免限流"))
            out["refreshIntervalSeconds"] = 30
        }
        if let th = out["thresholds"] as? [String: Any] {
            var t = th
            let yellow = (th["yellow"] as? NSNumber)?.intValue ?? 60
            let red = (th["red"] as? NSNumber)?.intValue ?? 85
            if !(yellow >= 0 && red <= 100 && yellow < red) {
                found.append(ConfigIssue("thresholds", "阈值需满足 0 ≤ yellow < red ≤ 100（当前 \(yellow)/\(red)）", "如 yellow=60, red=85"))
                t["yellow"] = 60
                t["red"] = 85
            }
            out["thresholds"] = t
        }
        for src in ["codex", "kimi", "mimo", "claudeCode"] {
            if let sec = out[src] as? [String: Any],
               let ri = sec["refreshIntervalSeconds"] as? NSNumber, ri.intValue < 30 {
                var s = sec
                found.append(ConfigIssue("\(src).refreshIntervalSeconds", "刷新间隔 \(ri.intValue)s 过短", "最小 30s"))
                s["refreshIntervalSeconds"] = 30
                out[src] = s
            }
        }
        if var codex = out["codex"] as? [String: Any] {
            if let port = (codex["proxyPort"] as? NSNumber)?.intValue, !(0...65535).contains(port) {
                found.append(ConfigIssue("codex.proxyPort", "代理端口 \(port) 越界", "0（禁用代理路）到 65535"))
                codex["proxyPort"] = 6152
            }
            if let retries = (codex["retries"] as? NSNumber)?.intValue, retries < 1 {
                found.append(ConfigIssue("codex.retries", "重试次数 \(retries) 至少为 1", "≥ 1"))
                codex["retries"] = 1
            }
            out["codex"] = codex
        }
        if var cc = out["claudeCode"] as? [String: Any], let servers = cc["servers"] as? [[String: Any]] {
            var kept: [[String: Any]] = []
            for (i, srv) in servers.enumerated() {
                var s = srv
                let host = s["host"] as? String ?? ""
                if host.isEmpty || !ShellSafety.isSafeSSHHost(host) {
                    found.append(ConfigIssue("claudeCode.servers[\(i)].host", "host \"\(host.prefix(40))\" 为空或含不允许字符", "只允许字母数字 . _ - : @（ssh 别名 / IP / user@host）"))
                    continue
                }
                if let port = s["sshPort"] as? String, !port.isEmpty,
                   let p = Int(port), !(1...65535).contains(p) {
                    found.append(ConfigIssue("claudeCode.servers[\(i)].sshPort", "sshPort \"\(port)\" 不是 1-65535", "留空用默认 22"))
                    s["sshPort"] = ""
                }
                if let user = s["user"] as? String, !user.isEmpty, !ShellSafety.isSafeUnixUsername(user) {
                    found.append(ConfigIssue("claudeCode.servers[\(i)].user", "user \"\(user.prefix(40))\" 不是合法系统用户名", "如 claude；留空=SSH 登录用户"))
                    s["user"] = ""
                }
                if let paths = s["paths"] as? [String] {
                    let ok = paths.filter { ShellSafety.isSafeRemotePath($0) }
                    if ok.count != paths.count {
                        found.append(ConfigIssue("claudeCode.servers[\(i)].paths", "路径含不允许字符（会被拼进远端命令）", "绝对路径，仅字母数字 . _ - /"))
                        s["paths"] = ok.isEmpty ? nil : ok
                    }
                }
                kept.append(s)
            }
            cc["servers"] = kept
            out["claudeCode"] = cc
        }
        if var zhipu = out["zhipu"] as? [String: Any], let keys = zhipu["keys"] as? [[String: Any]] {
            let kept = keys.filter { (($0["key"] as? String) ?? "").count > 8 }
            if kept.count != keys.count {
                found.append(ConfigIssue("zhipu.keys", "有 key 长度 ≤8 已忽略", "key 形如 id.suffix，完整粘贴"))
            }
            zhipu["keys"] = kept
            out["zhipu"] = zhipu
        }
        return (out, found)
    }
}

/// 配置仓库：启动读取一次，之后每 5s 轮询 mtime，有效变更整体替换、revision+1 并回调。
/// 整文件无效（缺失/JSON 解析失败）保留上一份有效配置并暴露问题。
/// 数据源不直接访问本类——配置通过 SourceConfiguration 值传递，刷新中的请求不会被半途改写；
/// 唯一例外是 language（后台线程生成本地化文案用，加锁读）。
public final class ConfigurationStore {
    public static let shared = ConfigurationStore()

    private let queue = DispatchQueue(label: "quotadock.config")
    private(set) var current: AppConfiguration
    private var lastContentHash: String
    private var lastMTime: Date?
    private var watchTimer: Timer?
    public let configPath: URL

    /// 热加载成功后的回调（主线程）
    public var onChange: ((AppConfiguration) -> Void)?

    /// 整文件级问题（文件缺失/解析失败）；字段级见 current.issues
    public private(set) var fileIssues: [ConfigIssue] = []

    /// 数据源在后台线程生成的本地化文案从这里取语言（线程安全）
    public var language: String {
        queue.sync { current.language }
    }

    public init(path: URL? = nil) {
        configPath = path ?? ConfigurationStore.defaultPath()
        let loaded = ConfigurationStore.loadFile(configPath)
        current = AppConfiguration(root: loaded.root, revision: 0)
        lastContentHash = ConfigurationStore.hash(loaded.root)
        lastMTime = loaded.mtime
        fileIssues = loaded.issues
    }

    public static func defaultPath() -> URL {
        if let p = ProcessInfo.processInfo.environment["QUOTADOCK_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quotadock/config.json")
    }

    static func loadFile(_ url: URL) -> (root: [String: Any], issues: [ConfigIssue], mtime: Date?) {
        guard let data = try? Data(contentsOf: url) else { return ([:], [], nil) }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([:], [ConfigIssue(url.lastPathComponent, "JSON 解析失败", "对照 config.example.json 检查逗号/引号")], mtime)
        }
        return (obj, [], mtime)
    }

    private static func hash(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 重新读取并应用（mtime 或内容变化时）。返回是否发生了有效替换。
    /// 整文件无效 → 保留旧配置 + 记录 fileIssues。
    @discardableResult
    public func reloadIfChanged() -> Bool {
        var applied = false
        queue.sync {
            let mtime = (try? configPath.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard mtime != lastMTime else { return }
            lastMTime = mtime
            let loaded = ConfigurationStore.loadFile(configPath)
            guard loaded.issues.isEmpty else {
                fileIssues = loaded.issues   // 保留上一份有效配置
                return
            }
            let h = ConfigurationStore.hash(loaded.root)
            guard h != lastContentHash else { return }
            lastContentHash = h
            fileIssues = []
            let previous = current
            current = AppConfiguration(root: loaded.root, revision: previous.revision + 1)
            applied = true
        }
        if applied, Thread.isMainThread {
            onChange?(currentSnapshot())
        }
        return applied
    }

    public func currentSnapshot() -> AppConfiguration {
        queue.sync { current }
    }

    /// 启动 mtime 轮询（默认 5s）。变化应用后主线程回调 onChange。
    public func startWatching(interval: TimeInterval = 5) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchTimer?.invalidate()
            self.watchTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self, self.reloadIfChanged() else { return }
                DispatchQueue.main.async {
                    self.onChange?(self.currentSnapshot())
                }
            }
        }
    }
}
