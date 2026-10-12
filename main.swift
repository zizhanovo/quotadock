// QuotaDock — macOS 多 AI 服务额度吸边仪表盘（悬浮卡片 + 收起吸边细条）
// 数据源: 智谱 / Codex / Kimi / MiMo / Claude Code VPS（全部只读，被动拉取）
// 配置: ~/.config/quotadock/config.json（缺省=内置默认值，字段见 config.example.json）
import AppKit
import CryptoKit
import SwiftUI
import Combine

// MARK: - 配置引擎（JSON；缺省即用；路径可用 QUOTADOCK_CONFIG 环境变量覆盖）

final class Conf {
    private let d: [String: Any]
    static let shared: Conf = {
        let path = ProcessInfo.processInfo.environment["QUOTADOCK_CONFIG"]
            ?? NSHomeDirectory() + "/.config/quotadock/config.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return Conf(obj: obj)
        }
        return Conf(obj: [:])
    }()
    private init(obj: [String: Any]) { d = obj }

    subscript(key: String) -> Conf? { (d[key] as? [String: Any]).map { Conf(obj: $0) } }

    func str(_ k: String, _ def: String = "") -> String { (d[k] as? String) ?? def }
    func int(_ k: String, _ def: Int) -> Int { (d[k] as? NSNumber)?.intValue ?? def }
    func dbl(_ k: String, _ def: Double) -> Double { (d[k] as? NSNumber)?.doubleValue ?? def }
    func bool(_ k: String, _ def: Bool) -> Bool { (d[k] as? Bool) ?? def }
    func list(_ k: String) -> [Conf] { (d[k] as? [[String: Any]] ?? []).map { Conf(obj: $0) } }
    /// 字符串字典（如 zhipu.names 的 providerId→显示名）
    func strDict(_ k: String) -> [String: String] {
        guard let obj = d[k] as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }
    /// 展开 ~ 的路径配置
    func path(_ k: String, _ def: String = "") -> String {
        let s = str(k, def)
        return s.hasPrefix("~") ? NSHomeDirectory() + String(s.dropFirst()) : s
    }
}

/// 双语文案：config `language` = "en" 时取英文，否则中文
func L(_ zh: String, _ en: String) -> String { Conf.shared.str("language", "zh") == "en" ? en : zh }

// MARK: - 模型

struct LimitEntry {
    let percentage: Int          // 已使用百分比
    let usage: Int?              // TIME_LIMIT: 总量(次)
    let currentValue: Int?       // TIME_LIMIT: 已用(次)
    let nextResetTime: Double?   // epoch 毫秒
}

struct QuotaData {
    let fiveHour: LimitEntry?
    let weekly: LimitEntry?
    let tools: LimitEntry?
    let level: String
    var maxPercentage: Int { [fiveHour?.percentage, weekly?.percentage].compactMap { $0 }.max() ?? 0 }
}

struct KeyQuota {
    let name: String        // 短名，如 "周卡"
    let keyTail: String     // key 后4位
    var quota: QuotaData?
    var error: String?
}

// MARK: - 配置发现 & 解析

func providerConfigPath() -> URL {
    URL(fileURLWithPath: Conf.shared["zhipu"]?.path("providerConfigPath", "~/.zcode/v2/provider_config.json") ?? "")
}

/// 自动发现所有智谱 Coding Plan key：access.type == zhipu-coding-plan-api-key
/// ZCode 加密凭据（~/.zcode/v2/credentials.json，enc:v1 = AES-256-GCM）。
/// 密钥 = SHA256(ZCODE_CREDENTIAL_SECRET env 或 fallback "zcode-credential-fallback:darwin:$HOME:$USER")。
/// 格式：enc:v1:<iv.b64url>.<tag.b64url>.<ct.b64url>
func zcodeDecrypt(_ enc: String) -> String? {
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

/// 个人账号 key：credentials.json 里 individual-coding-plan 的 api-key（enc:v1 加密）
func zcodeIndividualKey() -> (tail: String, key: String)? {
    let credPath = Conf.shared["zhipu"]?.path("credentialsPath", "~/.zcode/v2/credentials.json") ?? ""
    guard !credPath.isEmpty else { return nil }
    guard let raw = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: credPath))) as? [String: String] else { return nil }
    for (k, v) in raw where k.contains("individual-coding-plan") && k.hasSuffix("api-key") {
        guard let key = zcodeDecrypt(v), key.count > 8 else { continue }
        let tail = String(key.suffix(4))
        if zhipuSkipTails().contains(tail) { continue }
        return (tail, key)
    }
    return nil
}


// MARK: - 个人套餐自动敲窗（5h 用量≈0 时跑配置命令起算窗口；默认关闭，autoPing.enabled 开）

var autoPingInFlight = false
var lastAutoPing: Date?

func autoPingIfNeeded(personal: KeyQuota?) {
    guard let ap = Conf.shared["autoPing"], ap.bool("enabled", false) else { return }
    guard let q = personal?.quota, let five = q.fiveHour else { return }
    // 只在 5h 用量 ≤1%（窗口刚滚动/未激活）时敲
    guard five.percentage <= 1 else { return }
    // 防重入：敲后 10 分钟内不重复
    if let last = lastAutoPing, Date().timeIntervalSince(last) < 600 { return }
    if autoPingInFlight { return }
    let cmd = ap.str("command", "/opt/homebrew/bin/glm-ping")
    guard FileManager.default.isExecutableFile(atPath: cmd) else { return }
    autoPingInFlight = true
    lastAutoPing = Date()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: cmd)
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    DispatchQueue.global().async {
        defer { autoPingInFlight = false }
        do { try proc.run() } catch {
            print("[\(Date().formatted(date: .omitted, time: .standard))] auto-ping 启动失败: \(error.localizedDescription)")
            return
        }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("[\(Date().formatted(date: .omitted, time: .standard))] auto-ping: \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))")
        fflush(stdout)
    }
}


/// 失效 key 自动剔除：确认"身份验证失败"后尾号记入文件，之后不再查询。
/// 恢复监测：从 ~/.config/quotadock-skip.txt 删掉对应尾号。
let zhipuSkipFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/quotadock-skip.txt")

func zhipuSkipTails() -> [String] {
    guard let s = try? String(contentsOf: zhipuSkipFile, encoding: .utf8) else { return [] }
    return s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

func zhipuSkipAppend(_ tail: String) {
    var tails = zhipuSkipTails()
    guard !tails.contains(tail) else { return }
    tails.append(tail)
    try? FileManager.default.createDirectory(at: zhipuSkipFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? tails.joined(separator: "\n").write(to: zhipuSkipFile, atomically: true, encoding: .utf8)
}

func readAPIKeys() -> [(name: String, tail: String, key: String)] {
    let skipped = zhipuSkipTails()
    guard let data = try? Data(contentsOf: providerConfigPath()),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rules = (root["config"] as? [String: Any])?["providerConfigRules"] as? [String: Any],
          let list = rules["providerRules"] as? [[String: Any]] else { return [] }
    let shortNames = Conf.shared["zhipu"]?.strDict("names") ?? [:]
    var out: [(String, String, String)] = []
    for rule in list {
        let cfg = rule["config"] as? [String: Any] ?? [:]
        let access = cfg["access"] as? [String: Any] ?? [:]
        let pid = rule["providerId"] as? String ?? ""
        // 纳入两类：编码套餐类型的 key，或 bigmodel-* 前缀 provider 的普通 api-key
        // （月卡等以 standard api-key 形式配置，额度接口同样适用）
        let isPlan = access["type"] as? String == "zhipu-coding-plan-api-key"
        let isBigmodel = pid.hasPrefix("bigmodel-")
        guard isPlan || isBigmodel, let key = access["apiKey"] as? String else { continue }
        let name = shortNames[pid] ?? (rule["providerName"] as? String ?? pid)
        let tail = key.count >= 4 ? String(key.suffix(4)) : key
        if skipped.contains(tail) { continue }
        out.append((name, tail, key))
    }
    return out
}

func parseQuota(_ body: Data) -> QuotaData? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let data = root["data"] as? [String: Any],
          let limits = data["limits"] as? [[String: Any]] else { return nil }
    let level = data["level"] as? String ?? "-"

    func entry(_ d: [String: Any]) -> LimitEntry {
        LimitEntry(
            percentage: (d["percentage"] as? NSNumber)?.intValue ?? 0,
            usage: (d["usage"] as? NSNumber)?.intValue,
            currentValue: (d["currentValue"] as? NSNumber)?.intValue,
            nextResetTime: (d["nextResetTime"] as? NSNumber)?.doubleValue
        )
    }

    var tokenEntries: [(Int, LimitEntry)] = []   // (unit, entry)
    var tools: LimitEntry?
    for d in limits {
        let type = d["type"] as? String ?? ""
        if type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT" {
            tokenEntries.append(((d["unit"] as? NSNumber)?.intValue ?? 0, entry(d)))
        } else if type == "TIME_LIMIT" {
            tools = entry(d)
        }
    }
    // unit==3 → 5小时窗口, unit==6 → 周；兜底：重置时间离现在更近(<6h)的是5小时窗口
    var fiveHour = tokenEntries.first { $0.0 == 3 }?.1
    var weekly = tokenEntries.first { $0.0 == 6 }?.1
    if fiveHour == nil || weekly == nil, tokenEntries.count >= 2 {
        let now = Date().timeIntervalSince1970 * 1000
        let sorted = tokenEntries.sorted { ($0.1.nextResetTime ?? 0) < ($1.1.nextResetTime ?? 0) }
        if fiveHour == nil, let e = sorted.first, (e.1.nextResetTime ?? 0) - now < 6 * 3600 * 1000 {
            fiveHour = e.1
        }
        if weekly == nil {
            let candidates = sorted.filter { $0.1.nextResetTime != fiveHour?.nextResetTime }
            weekly = candidates.last?.1 ?? sorted.last?.1
        }
    }
    if fiveHour == nil, weekly == nil, let only = tokenEntries.first {
        weekly = only.1 // 只有一条时按周额度展示
    }
    return QuotaData(fiveHour: fiveHour, weekly: weekly, tools: tools, level: level)
}

// MARK: - 时间格式化

enum Fmt {
    private static func make(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: Conf.shared.str("timezone", "Asia/Shanghai")) ?? .current
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = fmt
        return f
    }
    static let hm = make("HH:mm")
    static let hms = make("HH:mm:ss")
    static let dateWeekHM = make("M月d日 EEEE HH:mm")
    static let bjTime = make("HH:mm")
    static let bjDateHM = make("M月d日 HH:mm")
}

/// "4小时48分后 · 20:30" 或 "6天23小时后 · 10月10日 15:22"（时区随 config）
func countdownString(_ ms: Double?) -> String? {
    guard let ms = ms else { return nil }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let diff = date.timeIntervalSinceNow
    let f = diff < 86400 ? Fmt.bjTime : Fmt.bjDateHM
    let bj = f.string(from: date)
    guard diff > 0 else { return L("已到点 · \(bj)", "due · \(bj)") }
    if diff < 3600 {
        return L("\(Int(diff / 60) + 1)分钟后 · \(bj)", "in \(Int(diff / 60) + 1)m · \(bj)")
    } else if diff < 86400 {
        let h = Int(diff / 3600), m = Int(diff.truncatingRemainder(dividingBy: 3600) / 60) + 1
        return L("\(h)小时\(m)分后 · \(bj)", "in \(h)h\(m)m · \(bj)")
    } else {
        let d = Int(diff / 86400), h = Int(diff.truncatingRemainder(dividingBy: 86400) / 3600)
        return L("\(d)天\(h)小时后 · \(bj)", "in \(d)d\(h)h · \(bj)")
    }
}

// MARK: - 用量配色（阈值可配：thresholds.yellow / thresholds.red）

func usageColor(_ used: Int) -> Color {
    let th = Conf.shared["thresholds"]
    let yellow = th?.int("yellow", 60) ?? 60
    let red = th?.int("red", 85) ?? 85
    if used < yellow { return Color(red: 0.20, green: 0.75, blue: 0.35) }
    if used < red { return Color(red: 0.95, green: 0.62, blue: 0.08) }
    return Color(red: 0.92, green: 0.26, blue: 0.22)
}

func usageNSColor(_ used: Int) -> NSColor {
    let th = Conf.shared["thresholds"]
    let yellow = th?.int("yellow", 60) ?? 60
    let red = th?.int("red", 85) ?? 85
    if used < yellow { return NSColor(red: 0.20, green: 0.75, blue: 0.35, alpha: 1) }
    if used < red { return NSColor(red: 0.95, green: 0.62, blue: 0.08, alpha: 1) }
    return NSColor(red: 0.92, green: 0.26, blue: 0.22, alpha: 1)
}

/// 收起态吸边方向：左右 → 竖条，上下 → 横条
enum DockEdge: String, CaseIterable { case top, bottom, left, right }

// MARK: - 数据层（ObservableObject，驱动菜单栏按钮和 Popover）

final class Store: ObservableObject {
    @Published var keyQuotas: [KeyQuota] = []
    @Published var lastUpdate: Date?
    @Published var lastError: String?
    @Published var extras: [ExtraService] = []
    @Published var selectedTails: [String]? {   // nil=未配置过(默认全显示)
        didSet { UserDefaults.standard.set(selectedTails, forKey: "displayKeys") }
    }
    @Published var autoOnly: Bool {             // 菜单栏只显示最紧张的那个
        didSet { UserDefaults.standard.set(autoOnly, forKey: "autoOnly") }
    }
    @Published var showRemaining: Bool {
        didSet { UserDefaults.standard.set(showRemaining, forKey: "showRemaining") }
    }
    @Published var stripMode = false            // 收起态=吸边细条（true 时窗口贴边）
    @Published var stripEdge: DockEdge          // 当前吸附的边：左右=竖条 / 上下=横条

    init() {
        selectedTails = UserDefaults.standard.array(forKey: "displayKeys") as? [String]
        autoOnly = UserDefaults.standard.bool(forKey: "autoOnly")
        showRemaining = UserDefaults.standard.bool(forKey: "showRemaining")
        stripEdge = UserDefaults.standard.string(forKey: "stripEdge").flatMap(DockEdge.init(rawValue:)) ?? .right
    }

    func isSelected(_ kq: KeyQuota) -> Bool {
        guard let sel = selectedTails else { return true }
        return sel.contains(kq.keyTail)
    }

    func toggleKey(_ tail: String) {
        var sel = selectedTails ?? keyQuotas.filter { isSelected($0) }.map { $0.keyTail }
        if let i = sel.firstIndex(of: tail) { sel.remove(at: i) } else { sel.append(tail) }
        selectedTails = sel
    }

    /// 菜单栏要显示的 key（按勾选过滤；autoOnly 时只留用量最高的）
    var visibleKeys: [KeyQuota] {
        let visible = keyQuotas.filter { isSelected($0) }
        guard autoOnly, !visible.isEmpty else { return visible }
        let worst = visible.max { ($0.quota?.maxPercentage ?? -1) < ($1.quota?.maxPercentage ?? -1) }
        return worst.map { [$0] } ?? []
    }

    /// force=true 时全部服务立即刷新（手动刷新按钮）；定时轮询走各服务独立节流
    func refreshAll(force: Bool = false) {
        var keys = readAPIKeys()
        if !zhipuSkipTails().contains("individual"), let ind = zcodeIndividualKey() {
            if !keys.contains(where: { $0.tail == ind.tail }) {
                keys.append((name: L("个人", "Personal"), tail: ind.tail, key: ind.key))
            }
        }
        // config 手工配置的 key（zhipu.keys: [{name, key}]）
        for k in Conf.shared["zhipu"]?.list("keys") ?? [] {
            let key = k.str("key")
            guard key.count > 8 else { continue }
            let tail = String(key.suffix(4))
            if !keys.contains(where: { $0.tail == tail }) {
                keys.append((name: k.str("name", L("自定义", "Custom")), tail: tail, key: key))
            }
        }
        guard !keys.isEmpty else {
            lastError = L("未发现智谱 key（provider 配置 / ZCode 个人账号 / config 均无）",
                          "no zhipu keys found (provider config / ZCode account / config)")
            keyQuotas = []
            return
        }
        // 新 key 补位，已有的保留旧数据避免刷新间隙闪空
        keyQuotas = keys.map { k in
            keyQuotas.first { $0.keyTail == k.tail }
                ?? KeyQuota(name: k.name, keyTail: k.tail, quota: nil, error: nil)
        }
        for (i, k) in keys.enumerated() { fetchOne(k, index: i) }
        // 个人套餐 5h 窗口耗尽后自动敲活（延迟到本轮数据回来后再判断）
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            if let personal = self.keyQuotas.first(where: { $0.name == "个人" }) {
                autoPingIfNeeded(personal: personal)
            }
        }
        refreshExtras(force: force)
    }

    /// 各服务上次抓取完成时间（per-service 节流）
    private var extraDue: [String: Date] = [:]

    /// 刷新其他服务（Codex / Kimi / MiMo / Claude Code VPS）。
    /// 每个服务有自己的 refreshIntervalSeconds（config），未到期的轮次直接跳过并保留上一轮的行；
    /// 手动刷新(force)无视节流。CC 快照只在有人用时才变，默认 600s 足够，SSH/网络开销降 2/3。
    private func refreshExtras(force: Bool = false) {
        let cfg = Conf.shared
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [ExtraService] = []
        var dispatched: [String] = []
        func add(_ fetch: (@escaping (ExtraService?) -> Void) -> Void) {
            group.enter()
            fetch { s in
                if let s { lock.lock(); results.append(s); lock.unlock() }
                group.leave()
            }
        }
        func due(_ key: String, _ interval: Int) -> Bool {
            force || Date() >= (extraDue[key] ?? .distantPast).addingTimeInterval(TimeInterval(max(30, interval)))
        }
        if cfg["codex"]?.bool("enabled", true) != false,
           due("codex", cfg["codex"]?.int("refreshIntervalSeconds", 180) ?? 180) {
            dispatched.append("codex"); add(fetchCodexService)
        }
        if cfg["kimi"]?.bool("enabled", true) != false,
           due("kimi", cfg["kimi"]?.int("refreshIntervalSeconds", 180) ?? 180) {
            dispatched.append("kimi"); add(fetchKimiService)
        }
        if cfg["mimo"]?.bool("enabled", true) != false,
           due("mimo", cfg["mimo"]?.int("refreshIntervalSeconds", 180) ?? 180) {
            dispatched.append("mimo"); add(fetchMiMoService)
        }
        let ccInterval = cfg["claudeCode"]?.int("refreshIntervalSeconds", 600) ?? 600
        for srv in cfg["claudeCode"]?.list("servers") ?? [] {
            let key = "cc." + srv.str("host")
            if due(key, ccInterval) {
                dispatched.append(key)
                add { fetchClaudeCodeService(server: srv, done: $0) }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            for k in dispatched { self.extraDue[k] = Date() }
            // 本轮没查的服务保留上一轮的行（节流时 UI 不掉行）
            var merged = results
            for old in self.extras where !merged.contains(where: { $0.name == old.name }) {
                merged.append(old)
            }
            self.extras = merged.sorted { ($0.usedPercent ?? -1) > ($1.usedPercent ?? -1) }
            let tag = dispatched.isEmpty ? "extras(skip)" : "extras(\(dispatched.joined(separator: ",")))"
            print("[\(self.stamp())] \(tag): " + self.extras.map { "\($0.name)=\($0.value) [\($0.detail)]" }.joined(separator: " | "))
            fflush(stdout)
        }
    }

    private func fetchOne(_ k: (name: String, tail: String, key: String), index: Int) {
        var req = URLRequest(url: URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!)
        req.timeoutInterval = 15
        req.setValue("Bearer " + k.key, forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            DispatchQueue.main.async {
                guard let self, index < self.keyQuotas.count else { return }
                if let error = error {
                    // 网络抖动：保留旧数据不闪空
                    self.keyQuotas[index].error = L("网络错误", "network error") + ": \(error.localizedDescription)"
                } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    // 只有 401/403 是服务端确认身份失效；429/5xx 是临时故障，
                    // 保留旧数据、不写 skip，避免一次限流永久禁用有效 key
                    if http.statusCode == 401 || http.statusCode == 403 {
                        self.keyQuotas[index].quota = nil
                        zhipuSkipAppend(k.tail)
                        self.keyQuotas[index].error = L("已失效", "invalid") + " · HTTP \(http.statusCode)"
                    } else if http.statusCode == 429 {
                        self.keyQuotas[index].error = L("限流，稍后自动重试", "rate limited, will retry") + " · HTTP 429"
                    } else {
                        self.keyQuotas[index].error = L("服务端错误", "server error") + " · HTTP \(http.statusCode)"
                    }
                } else if let data = data, let q = parseQuota(data) {
                    self.keyQuotas[index].quota = q
                    self.keyQuotas[index].error = nil
                    self.lastUpdate = Date()
                    print("[\(self.stamp())] \(k.name)(…\(k.tail)) 刷新成功 5h=\(q.fiveHour.map { "\($0.percentage)%" } ?? "-") 周=\(q.weekly.map { "\($0.percentage)%" } ?? "-")")
                    fflush(stdout)
                } else {
                    // 200 但无额度数据：仅当响应明确说"身份验证失败"（code 1000）才算确认失效；
                    // 其余解析失败视为临时故障，保留旧数据、不写 skip
                    var msg = L("响应无效", "invalid response")
                    var identityRejected = false
                    if let data,
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let m = obj["msg"] as? String { msg = m }
                        if (obj["code"] as? NSNumber)?.intValue == 1000 || (msg as NSString).contains("身份验证") {
                            identityRejected = true
                        }
                    }
                    if identityRejected {
                        self.keyQuotas[index].quota = nil
                        zhipuSkipAppend(k.tail)
                        self.keyQuotas[index].error = L("已失效", "invalid") + " · \(msg)"
                    } else {
                        self.keyQuotas[index].error = L("响应异常，保留上次数据", "bad response, kept last data") + " · \(msg)"
                    }
                }
            }
        }.resume()
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - SwiftUI 卡片面板

// MARK: - 其他服务（Codex / Kimi）

struct ExtraService {
    let name: String
    let value: String        // 右侧主数值（有进度条时放数据时间）
    let detail: String       // 第二行说明
    let usedPercent: Int?    // 状态色依据；nil=无用量概念
    var fiveBar: LimitEntry? = nil   // 有值时渲染 5h/周 双进度条（Claude Code VPS）
    var weekBar: LimitEntry? = nil
    var stale: Bool = false          // 数据停更超 24h，⚠ 标橙
}

/// Codex：用 ~/.codex/auth.json 的 ChatGPT OAuth token 查官方用量接口。
/// chatgpt.com 的出口 IP 会被 Cloudflare 间歇性 403（VPN 出口轮换导致），直连/代理交替重试，
/// 全失败时展示最近一次成功值（标注缓存时间）。
func codexLastGoodRead() -> (name: String, value: String, detail: String, pct: Int?, at: Date)? {
    guard let d = UserDefaults.standard.dictionary(forKey: "codexLastGood"),
          let name = d["name"] as? String, let value = d["value"] as? String,
          let detail = d["detail"] as? String, let at = d["at"] as? Date else { return nil }
    let pct = d["pct"] as? Int
    return (name, value, detail, pct, at)
}
func codexLastGoodWrite(_ g: (name: String, value: String, detail: String, pct: Int?, at: Date)) {
    UserDefaults.standard.set(["name": g.name, "value": g.value, "detail": g.detail, "pct": g.pct ?? -1, "at": g.at], forKey: "codexLastGood")
}

func fetchCodexService(done: @escaping (ExtraService?) -> Void) {
    let authPath = Conf.shared["codex"]?.path("authPath", "~/.codex/auth.json") ?? ""
    guard let auth = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: authPath))) as? [String: Any],
          let tokens = auth["tokens"] as? [String: Any],
          let tok = tokens["access_token"] as? String,
          let acct = tokens["account_id"] as? String else { done(nil); return }
    var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/usage")!)
    req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
    req.setValue(acct, forHTTPHeaderField: "chatgpt-account-id")
    req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
    req.timeoutInterval = 10

    DispatchQueue.global(qos: .utility).async {
        var lastStatus = 0
        // 直连/代理交替重试，赌出口 IP 轮换；proxyPort 配 0 = 禁用代理路。
        // 失败间隙用 asyncAfter 调度，不 Thread.sleep 占线程。
        let ccfg = Conf.shared["codex"]
        let proxyHost = ccfg?.str("proxyHost", "127.0.0.1") ?? "127.0.0.1"
        let proxyPort = ccfg?.int("proxyPort", 6152) ?? 6152
        let retryGap = ccfg?.dbl("retryIntervalSeconds", 15) ?? 15
        let n = max(1, ccfg?.int("retries", 4) ?? 4)
        let sequence: [Bool] = (0..<n).map { proxyPort > 0 && $0 % 2 == 1 }
        let q = DispatchQueue.global(qos: .utility)
        func finish() {
            DispatchQueue.main.async {
                if let g = codexLastGoodRead() {
                    let f = DateFormatter()
                    f.dateFormat = "HH:mm"
                    done(ExtraService(name: g.name, value: g.value, detail: L("缓存 \(f.string(from: g.at))", "cached \(f.string(from: g.at))") + " · \(g.detail)", usedPercent: g.pct))
                } else {
                    done(ExtraService(name: "Codex", value: "❌", detail: L("获取失败", "fetch failed") + " HTTP \(lastStatus)", usedPercent: nil))
                }
            }
        }
        func attempt(_ i: Int) {
            guard i < sequence.count else { finish(); return }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = sequence[i]
                ? ["HTTPSEnable": 1, "HTTPSProxy": proxyHost, "HTTPSPort": proxyPort,
                   "HTTPEnable": 1, "HTTPProxy": proxyHost, "HTTPPort": proxyPort]
                : [:]
            cfg.timeoutIntervalForRequest = 10
            let sem = DispatchSemaphore(value: 0)
            var status = 0, data: Data?
            URLSession(configuration: cfg).dataTask(with: req) { d, r, _ in
                status = (r as? HTTPURLResponse)?.statusCode ?? 0
                data = d
                sem.signal()
            }.resume()
            sem.wait()
            lastStatus = status
            if status == 200,
               let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] {
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
                let value = pct.map { "\($0)%" } ?? "-"
                codexLastGoodWrite((name, value, detail, pct, Date()))
                DispatchQueue.main.async {
                    done(ExtraService(name: name, value: value, detail: detail, usedPercent: pct))
                }
                return
            }
            // 出口轮换是几十秒级，拉开重试间隔（不占线程）
            q.asyncAfter(deadline: .now() + retryGap) { attempt(i + 1) }
        }
        attempt(0)
    }
}

/// Kimi：GET /coding/v1/usages 查套餐额度（5小时窗口 + 周额度，复数 usages！）。
/// access_token 仅 15 分钟有效且无法本地静默续期（refresh 绑定原始设备会话），
/// token 过期时展示最近成功值（UserDefaults 持久化，标注缓存时间）。
func kimiLastGoodRead() -> (value: String, detail: String, pct: Int?, at: Date)? {
    guard let d = UserDefaults.standard.dictionary(forKey: "kimiLastGood"),
          let value = d["value"] as? String, let detail = d["detail"] as? String,
          let at = d["at"] as? Date else { return nil }
    return (value, detail, d["pct"] as? Int, at)
}

func fetchKimiService(done: @escaping (ExtraService?) -> Void) {
    let credPath = Conf.shared["kimi"]?.path("credentialsPath", "~/.kimi-code/credentials/kimi-code.json") ?? ""
    guard let cred = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: credPath))) as? [String: Any],
          let tok = cred["access_token"] as? String else {
        if let g = kimiLastGoodRead() { done(ExtraService(name: "Kimi", value: g.value, detail: L("缓存", "cached") + " · \(g.detail)", usedPercent: g.pct)) }
        else { done(nil) }
        return
    }
    let fresh = ((cred["expires_at"] as? NSNumber)?.doubleValue ?? 0) > Date().timeIntervalSince1970 + 30
    var req = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!)
    req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any],
              let usages = obj["usages"] as? [String: Any],
              let h5 = usages["limit_5h"] as? [String: Any],
              let w7 = usages["limit_7d"] as? [String: Any],
              let r5 = (h5["used_ratio"] as? NSNumber)?.doubleValue,
              let r7 = (w7["used_ratio"] as? NSNumber)?.doubleValue else {
            DispatchQueue.main.async {
                if let g = kimiLastGoodRead() {
                    let f = DateFormatter(); f.dateFormat = "HH:mm"
                    done(ExtraService(name: "Kimi", value: g.value, detail: L("缓存 \(f.string(from: g.at))", "cached \(f.string(from: g.at))") + " · \(g.detail)", usedPercent: g.pct))
                } else {
                    let hint = fresh ? L("获取失败", "fetch failed") + " HTTP \(status)" : L("token 过期 · 跑一次 kimi CLI 自动续期", "token expired · run kimi CLI to refresh")
                    done(ExtraService(name: "Kimi", value: "❌", detail: hint, usedPercent: nil))
                }
            }
            return
        }
        let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        func pct(_ ratio: Double) -> Int { Int((ratio * 100).rounded()) }
        func resetBeijing(_ s: String) -> String {
            let date = isoFrac.date(from: s) ?? iso.date(from: s)
            guard let date else { return "" }
            let diff = date.timeIntervalSinceNow
            let f = diff < 86400 ? Fmt.bjTime : Fmt.bjDateHM
            return f.string(from: date)
        }
        let p5 = pct(r5), p7 = pct(r7)
        let r5s = resetBeijing(h5["reset_time"] as? String ?? "")
        let r7s = resetBeijing(w7["reset_time"] as? String ?? "")
        let top = max(p5, p7)
        let value = "\(top)%"
        let detail = "5h \(p5)% · \(L("周", "wk")) \(p7)% · \(L("重置", "reset")) \(r5s) / \(r7s)"
        UserDefaults.standard.set(["value": value, "detail": detail, "pct": top, "at": Date()], forKey: "kimiLastGood")
        DispatchQueue.main.async {
            done(ExtraService(name: "Kimi", value: value, detail: detail, usedPercent: top))
        }
    }.resume()
}

/// MiMo 套餐额度：纯被动读本地缓存（mimo-usage-sync 写入），QuotaDock 不碰凭据、不发请求。
/// 官方接口 percent 是「剩余」，缓存里同时给出 usedPercent；数据停更超 24h 标 ⚠。
func fetchMiMoService(done: @escaping (ExtraService?) -> Void) {
    let path = Conf.shared["mimo"]?.path("cachePath", "~/.cache/quotadock/mimo-usage.json")
        ?? NSHomeDirectory() + "/.cache/quotadock/mimo-usage.json"
    DispatchQueue.global(qos: .utility).async {
        func empty(_ hint: String) -> ExtraService {
            ExtraService(name: "MiMo", value: "—", detail: hint, usedPercent: nil)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["ok"] as? Bool) == true,
              let usage = obj["usage"] as? [String: Any],
              let used = (usage["usedPercent"] as? NSNumber)?.doubleValue else {
            DispatchQueue.main.async {
                done(empty(L("跑 mimo-usage-sync 同步额度", "run mimo-usage-sync to sync")))
            }
            return
        }
        let remaining = (usage["remainingPercent"] as? NSNumber)?.doubleValue ?? (100 - used)
        let resetDate = usage["resetDate"] as? String ?? ""
        let plan = ((obj["subscription"] as? [String: Any])?["title"] as? String)
            ?? ((obj["subscription"] as? [String: Any])?["planCode"] as? String)
            ?? ""
        let fetchedAt = Date(timeIntervalSince1970: (obj["fetchedAt"] as? NSNumber)?.doubleValue ?? 0)
        let age = Date().timeIntervalSince(fetchedAt)
        let stale = age > 86400
        let when = (stale ? "⚠ " + L("停更于 ", "stale since ") : L("更新 ", "updated "))
            + (age < 86400 ? Fmt.bjTime.string(from: fetchedAt) : Fmt.bjDateHM.string(from: fetchedAt))
        let pctUsed = Int(used.rounded())
        var detail = L("已用 \(pctUsed)%", "used \(pctUsed)%")
            + " · " + L("剩余 \(Int(remaining.rounded()))%", "left \(Int(remaining.rounded()))%")
        if !resetDate.isEmpty { detail += " · " + L("重置", "reset") + " \(resetDate)" }
        if !plan.isEmpty { detail += " · \(plan)" }
        let row = ExtraService(name: "MiMo", value: when, detail: detail, usedPercent: pctUsed, stale: stale)
        DispatchQueue.main.async { done(row) }
    }
}

// MARK: - Claude Code（远程 VPS）
// 优先 SSH 在服务器上跑一次 `claude -p /usage` 刷新缓存（凭据/流量都留在 VPS，走其静态 IP 出口），
// 再只读 cachedUsageUtilization。可配置 claudeCode.refreshUsage=false 回到纯被动模式。
// 服务器在 config `claudeCode.servers` 配置：{host, name?, paths?, user?}。

// CC lastGood 缓存：SSH 走跳板时两级握手 ~5s，ConnectTimeout 稍紧或跳板抖动就会失败
// （多台同跳板会同时挂）。与 Codex/Kimi 同策略：失败间隙展示最近成功值，标注缓存时间。
func ccLastGoodWrite(_ label: String, _ row: ExtraService) {
    UserDefaults.standard.set(["name": row.name, "value": row.value, "detail": row.detail,
                               "pct": row.usedPercent ?? -1,
                               "fiveP": row.fiveBar?.percentage ?? -1, "fiveReset": row.fiveBar?.nextResetTime ?? 0,
                               "weekP": row.weekBar?.percentage ?? -1, "weekReset": row.weekBar?.nextResetTime ?? 0,
                               "at": Date()], forKey: "ccLastGood.\(label)")
}
func ccCachedRow(_ label: String) -> ExtraService? {
    guard let d = UserDefaults.standard.dictionary(forKey: "ccLastGood.\(label)") else { return nil }
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let at = d["at"] as? Date ?? Date()
    func bar(_ p: String, _ r: String) -> LimitEntry? {
        guard let pv = d[p] as? Int, pv >= 0 else { return nil }
        let rv = d[r] as? Double ?? 0
        return LimitEntry(percentage: pv, usage: nil, currentValue: nil, nextResetTime: rv > 0 ? rv : nil)
    }
    let pct = d["pct"] as? Int
    return ExtraService(name: d["name"] as? String ?? "CC \(label)",
                        value: L("缓存 \(f.string(from: at))", "cached \(f.string(from: at))"),
                        detail: d["detail"] as? String ?? "",
                        usedPercent: (pct == nil || pct! < 0) ? nil : pct,
                        fiveBar: bar("fiveP", "fiveReset"), weekBar: bar("weekP", "weekReset"),
                        stale: Date().timeIntervalSince(at) > 86400)
}

func fetchClaudeCodeService(server: Conf, done: @escaping (ExtraService?) -> Void) {
    let host = server.str("host")
    guard !host.isEmpty else { done(nil); return }
    let label = server.str("name", host)
    var paths = server.list("paths").map { $0.str("path") }.filter { !$0.isEmpty }
    if paths.isEmpty { paths = ["/home/claude/.claude.json", "/root/.claude.json"] }
    let pyPaths = paths.map { "'\($0)'" }.joined(separator: ",")
    let sshPort = server.str("sshPort", "")
    let portArgs = sshPort.isEmpty ? [] : ["-p", sshPort]
    // 2.1.x 起普通对话不再写 cachedUsageUtilization；在服务器上跑 /usage 才会刷新。
    // 只允许在远端执行，禁止把 VPS 凭据拿到本机调用。
    let refreshUsage = Conf.shared["claudeCode"]?.bool("refreshUsage", true) ?? true
    let runAs = server.str("user", "")  // 空 = SSH 登录用户（通常是 root）
    var prelude = ""
    if refreshUsage {
        let claudeCmd = runAs.isEmpty ? "claude -p /usage" : "sudo -u \(runAs) -n claude -p /usage"
        prelude = "\(claudeCmd) >/dev/null 2>&1; "
    }
    let cmd = prelude + "python3 -c \"import json,os\nc=[]\nfor p in [\(pyPaths)]:\n if os.path.exists(p):\n  d=json.load(open(p));u=d.get('cachedUsageUtilization')\n  if u:c.append((u.get('fetchedAtMs',0),(d.get('oauthAccount') or {}).get('emailAddress'),u))\nb=max(c) if c else None\nprint(json.dumps({'email':(b[1] if b else None),'u':(b[2] if b else None)}))\""
    DispatchQueue.global(qos: .utility).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "ConnectTimeout=\(Conf.shared["claudeCode"]?.int("sshConnectTimeout", 10) ?? 10)",
                    "-o", "BatchMode=yes"]
        // 连接复用：同一 host 的后续轮询走常驻 master，跳板/握手开销归零
        if Conf.shared["claudeCode"]?.bool("sshMultiplexing", true) ?? true {
            args += ["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/quotadock-ssh-%C", "-o", "ControlPersist=1800"]
        }
        p.arguments = args + portArgs + [host, cmd]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch {
            DispatchQueue.main.async { done(ExtraService(name: "CC \(label)", value: "❌", detail: L("SSH 启动失败", "SSH launch failed"), usedPercent: nil)) }
            return
        }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
            let row = ccCachedRow(label) ?? ExtraService(name: "CC \(label)", value: "❌", detail: L("SSH 失败（网络/跳板?）", "SSH failed"), usedPercent: nil)
            DispatchQueue.main.async { done(row) }
            return
        }
        let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        let bjShort = DateFormatter()
        bjShort.timeZone = TimeZone(identifier: Conf.shared.str("timezone", "Asia/Shanghai")) ?? .current
        bjShort.dateFormat = "M/d HH:mm"
        func build() -> ExtraService? {
            guard let u = obj["u"] as? [String: Any],
                  let util = u["utilization"] as? [String: Any],
                  let h5 = util["five_hour"] as? [String: Any],
                  let w7 = util["seven_day"] as? [String: Any],
                  let p5 = (h5["utilization"] as? NSNumber)?.intValue,
                  let p7 = (w7["utilization"] as? NSNumber)?.intValue else { return nil }
            let fetched = Date(timeIntervalSince1970: ((u["fetchedAtMs"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            func resetMs(_ d: [String: Any]) -> Double? {
                guard let s = d["resets_at"] as? String,
                      let t = isoFrac.date(from: s) ?? iso.date(from: s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)) else { return nil }
                return t.timeIntervalSince1970 * 1000
            }
            let top = max(p5, p7)
            let stale = Date().timeIntervalSince(fetched)
            let when = (stale > 86400 ? "⚠ " + L("停更于 ", "stale since ") : L("更新 ", "updated "))
                + (stale < 86400 ? Fmt.bjTime.string(from: fetched) : bjShort.string(from: fetched))
            return ExtraService(
                name: "CC \(label)", value: when, detail: "5h \(p5)% · \(L("周", "wk")) \(p7)%",
                usedPercent: top,
                fiveBar: LimitEntry(percentage: p5, usage: nil, currentValue: nil, nextResetTime: resetMs(h5)),
                weekBar: LimitEntry(percentage: p7, usage: nil, currentValue: nil, nextResetTime: resetMs(w7)),
                stale: stale > 86400
            )
        }
        let built = build()
        if let r = built { ccLastGoodWrite(label, r) }
        let result = built ?? ExtraService(name: "CC \(label)", value: "—", detail: L("尚无使用缓存", "no usage cache yet"), usedPercent: nil)
        DispatchQueue.main.async { done(result) }
    }
}

// MARK: - 常驻迷你仪表盘

/// 短倒计时："4小时22分" / "6天23小时" / "38分"
func shortCountdown(_ ms: Double?) -> String {
    guard let ms = ms else { return "-" }
    let diff = Date(timeIntervalSince1970: ms / 1000).timeIntervalSinceNow
    guard diff > 0 else { return L("已到点", "due") }
    if diff < 3600 { return L("\(Int(diff / 60) + 1)分", "\(Int(diff / 60) + 1)m") }
    if diff < 86400 {
        return L("\(Int(diff / 3600))小时\(Int(diff.truncatingRemainder(dividingBy: 3600) / 60) + 1)分",
                 "\(Int(diff / 3600))h\(Int(diff.truncatingRemainder(dividingBy: 3600) / 60) + 1)m")
    }
    return L("\(Int(diff / 86400))天\(Int(diff.truncatingRemainder(dividingBy: 86400) / 3600))小时",
             "\(Int(diff / 86400))d\(Int(diff.truncatingRemainder(dividingBy: 86400) / 3600))h")
}

/// 单行内联进度条："5h ▓▓▓░░ 23%"
struct MiniBar: View {
    let label: String
    let entry: LimitEntry?
    let showRemaining: Bool

    private var used: Int { min(entry?.percentage ?? 0, 100) }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: 15, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.13))
                    Capsule().fill(usageColor(used))
                        .frame(width: max(2, geo.size.width * CGFloat(used) / 100))
                }
            }
            .frame(height: 5)
            Text(entry == nil ? "-" : "\(showRemaining ? 100 - used : used)%")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(entry == nil ? Color.secondary : usageColor(used))
                .frame(width: 28, alignment: .trailing)
        }
    }
}

/// 一个 key 的分节：名称行 + 两条 MiniBar + 重置行
struct MiniKeySection: View {
    let kq: KeyQuota
    let showRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(usageColor(kq.quota?.maxPercentage ?? 0))
                    .frame(width: 6, height: 6)
                Text(kq.name).font(.system(size: 11, weight: .semibold))
                Text("…\(kq.keyTail)").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                if let q = kq.quota {
                    Text(q.level.uppercased())
                        .font(.system(size: 8, weight: .bold)).tracking(0.5)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .foregroundStyle(.secondary)
                }
            }
            if let q = kq.quota {
                MiniBar(label: "5h", entry: q.fiveHour, showRemaining: showRemaining)
                MiniBar(label: L("周", "wk"), entry: q.weekly, showRemaining: showRemaining)
                Text(L("重置 5h \(shortCountdown(q.fiveHour?.nextResetTime)) · \(L("周", "wk")) \(shortCountdown(q.weekly?.nextResetTime))",
                      "reset 5h \(shortCountdown(q.fiveHour?.nextResetTime)) · wk \(shortCountdown(q.weekly?.nextResetTime))"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text("❌ \(kq.error ?? "尚未获取")").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 悬停浮现的设置条（覆盖在卡片底部，不改变窗口尺寸）
struct HoverControls: View {
    @ObservedObject var store: Store
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(L("显示", "Show")).font(.system(size: 9)).foregroundStyle(.tertiary)
                ForEach(store.keyQuotas, id: \.keyTail) { kq in
                    Button { store.toggleKey(kq.keyTail) } label: {
                        HStack(spacing: 2) {
                            Image(systemName: store.isSelected(kq) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 9))
                            Text(kq.name).font(.system(size: 10))
                        }
                        .foregroundStyle(store.isSelected(kq) ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Toggle(L("剩余%", "Left%"), isOn: $store.showRemaining)
                    .toggleStyle(.checkbox).controlSize(.mini).font(.system(size: 9))
                    .help(L("数字显示剩余百分比", "Show remaining percentage"))
            }
            HStack {
                Toggle(L("自动切换", "Auto switch"), isOn: $store.autoOnly)
                    .toggleStyle(.checkbox).controlSize(.mini).font(.system(size: 9))
                    .help(L("只显示用量最高的 key", "Show only the busiest key"))
                Spacer()
                Button(L("收起", "Collapse")) { onCollapse() }
                    .buttonStyle(.borderless).font(.system(size: 9)).foregroundStyle(.secondary)
                Button(L("退出", "Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
        .padding(4)
    }
}

/// 默认形态：常驻迷你仪表盘（所有信息免点击可见）
struct MiniDashboardView: View {
    @ObservedObject var store: Store
    var onCollapse: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(Fmt.dateWeekHM.string(from: ctx.date))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button { store.refreshAll(force: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("立即刷新")
            }
            if store.keyQuotas.isEmpty {
                Text("❌ \(store.lastError ?? L("未发现智谱 key", "no zhipu keys"))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(store.keyQuotas.indices, id: \.self) { i in
                MiniKeySection(kq: store.keyQuotas[i], showRemaining: store.showRemaining)
            }
            if !store.extras.isEmpty {
                Divider()
                ForEach(Array(store.extras.enumerated()), id: \.offset) { _, s in
                    if let five = s.fiveBar, let week = s.weekBar {
                        // Claude Code VPS：5h/周双进度条 + 重置倒计时，与智谱分节同款样式
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(s.usedPercent.map { usageColor($0) } ?? Color.gray)
                                    .frame(width: 6, height: 6)
                                Text(s.name).font(.system(size: 10, weight: .semibold))
                                Spacer(minLength: 8)
                                Text(s.value)
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(s.stale ? Color.orange : Color.secondary)
                            }
                            MiniBar(label: "5h", entry: five, showRemaining: store.showRemaining)
                            MiniBar(label: "周", entry: week, showRemaining: store.showRemaining)
                            Text("重置 5h \(shortCountdown(five.nextResetTime)) · 周 \(shortCountdown(week.nextResetTime))")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(s.usedPercent.map { usageColor($0) } ?? Color.gray)
                                    .frame(width: 6, height: 6)
                                Text(s.name).font(.system(size: 10, weight: .semibold))
                                Spacer(minLength: 8)
                                Text(s.value)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(s.usedPercent.map { usageColor($0) } ?? Color.secondary)
                            }
                            Text(s.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 232, alignment: .topLeading)
        .frame(minHeight: 172, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .overlay(alignment: .bottom) {
            if hovering {
                HoverControls(store: store, onCollapse: { hovering = false; onCollapse?() })
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .windowDrag()
    }
}

// MARK: - 悬浮窗拖动手势（显式实现，不依赖 isMovableByWindowBackground 在 SwiftUI 上的表现）

struct WindowDragModifier: ViewModifier {
    @State private var startOrigin: NSPoint?
    @State private var cursorOffset = NSZeroPoint

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 2)
                // 不用 translation（它在随窗口移动的视图坐标系里，会形成反馈回路导致抖动），
                // 直接用鼠标全局坐标减去按下时的偏移来定位窗口
                .onChanged { _ in
                    guard let w = NSApp.windows.first(where: { $0 is NSPanel }) else { return }
                    let mouse = NSEvent.mouseLocation
                    if startOrigin == nil {
                        startOrigin = w.frame.origin
                        cursorOffset = NSPoint(x: mouse.x - startOrigin!.x, y: mouse.y - startOrigin!.y)
                    }
                    var f = w.frame
                    f.origin.x = mouse.x - cursorOffset.x
                    f.origin.y = mouse.y - cursorOffset.y
                    if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
                        let vis = s.visibleFrame
                        f.origin.x = min(max(f.origin.x, vis.minX), max(vis.minX, vis.maxX - f.width))
                        f.origin.y = min(max(f.origin.y, vis.minY), max(vis.minY, vis.maxY - f.height))
                    }
                    w.setFrame(f, display: true)
                }
                .onEnded { _ in
                    if let w = NSApp.windows.first(where: { $0 is NSPanel }) {
                        let mouse = NSEvent.mouseLocation
                        if let del = NSApp.delegate as? AppDelegate, del.store.stripMode {
                            // 吸边条拖拽结束：按落点最近的边重新吸附（左右=竖条 / 上下=横条）
                            del.stripDragEnded(mouse: mouse)
                        } else {
                            UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "panelFrame")
                        }
                    }
                    startOrigin = nil
                }
        )
    }
}

extension View {
    func windowDrag() -> some View { modifier(WindowDragModifier()) }
}

/// 形态切换：仪表盘（默认）↔ 吸边细条（悬停设置里"收起"，点细条回来）
struct PanelRootView: View {
    @ObservedObject var store: Store
    @State private var collapsed: Bool

    init(store: Store, initiallyCollapsed: Bool = false) {
        self.store = store
        _collapsed = State(initialValue: initiallyCollapsed)
    }

    var body: some View {
        if collapsed {
            EdgeStrip(store: store, onTap: {
                withAnimation(.easeOut(duration: 0.15)) { collapsed = false; store.stripMode = false }
            })
        } else {
            MiniDashboardView(store: store, onCollapse: {
                withAnimation(.easeOut(duration: 0.15)) {
                    collapsed = true
                    store.stripMode = true
                    let e = nearestDockEdgeFromPanel()
                    store.stripEdge = e
                    UserDefaults.standard.set(e.rawValue, forKey: "stripEdge")
                }
            })
        }
    }
}

/// 面板中心点离哪条屏幕边最近 → 收起时吸哪条
func nearestDockEdgeFromPanel() -> DockEdge {
    guard let w = NSApp.windows.first(where: { $0 is NSPanel }) else { return .right }
    let c = NSPoint(x: w.frame.midX, y: w.frame.midY)
    let screen = NSScreen.screens.first(where: { $0.frame.contains(c) }) ?? NSScreen.main
    guard let v = screen?.visibleFrame else { return .right }
    let dists: [(DockEdge, CGFloat)] = [(.top, v.maxY - c.y), (.bottom, c.y - v.minY),
                                         (.left, c.x - v.minX), (.right, v.maxX - c.x)]
    return dists.min(by: { $0.1 < $1.1 })?.0 ?? .right
}

/// 吸边条（收起态）：顶/底吸附=横条，左/右吸附=竖条。
/// 全部项按紧张度降序，每项「彩色大号百分比 + 品牌logo/首字块」；悬停 tooltip 列名称明细；
/// 点击恢复仪表盘，按住拖到别的边松手换边换方向。
struct EdgeStrip: View {
    @ObservedObject var store: Store
    let onTap: () -> Void

    struct StripItem { let name: String; let used: Int?; let logo: String?; let badge: Int? }

    /// 名称 → 品牌图标 id（logos/ 目录下的同名 .svg/.png）；nil=无品牌图走首字块
    static func logoID(for name: String) -> String? {
        if name.hasPrefix("Codex") { return "openai" }
        if name.hasPrefix("CC ") { return "claude" }
        if name.hasPrefix("Kimi") { return "kimi" }
        if name.hasPrefix("MiMo") { return "xiaomi" }
        return nil
    }

    private var items: [StripItem] {
        var raw: [(String, Int?, String?)] = []
        for k in store.visibleKeys {
            raw.append((k.name, k.quota.map { min(max($0.maxPercentage, 0), 100) }, "zhipu"))
        }
        for s in store.extras {
            if let u = s.usedPercent { raw.append((s.name, min(u, 100), EdgeStrip.logoID(for: s.name))) }
        }
        var counts: [String: Int] = [:]
        for r in raw where r.2 != nil { counts[r.2!, default: 0] += 1 }
        var idx: [String: Int] = [:]
        return raw.map {
            guard let lid = $0.2 else { return StripItem(name: $0.0, used: $0.1, logo: nil, badge: nil) }
            idx[lid, default: 0] += 1
            // 同 logo 多个实例（如两台 CC）才显示 ①② 角标
            let badge = (counts[lid] ?? 0) > 1 ? idx[lid] : nil
            return StripItem(name: $0.0, used: $0.1, logo: lid, badge: badge)
        }
    }

    /// logo 目录：优先 QUOTADOCK_LOGOS 环境变量（离屏渲染用），否则 app bundle Resources/logos
    static func logosDir() -> URL? {
        if let p = ProcessInfo.processInfo.environment["QUOTADOCK_LOGOS"] { return URL(fileURLWithPath: p) }
        return Bundle.main.resourceURL?.appendingPathComponent("logos")
    }
    private static var logoCache: [String: NSImage?] = [:]
    private static func logoImage(_ id: String) -> NSImage? {
        if let c = logoCache[id] { return c }
        var img: NSImage?
        for ext in ["svg", "png"] {
            if let u = EdgeStrip.logosDir()?.appendingPathComponent("\(id).\(ext)") {
                img = NSImage(contentsOf: u)
                if img != nil { break }
            }
        }
        img?.isTemplate = true   // 单色模板渲染，深浅模式统一 secondary 灰
        logoCache[id] = img
        return img
    }

    /// 识别块：品牌 logo（文件缺失/加载失败回退首字块）；智谱多卡同 logo 靠 ①② 角标区分
    @ViewBuilder
    private func ident(_ it: StripItem) -> some View {
        if let lid = it.logo, let img = EdgeStrip.logoImage(lid) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: img).resizable().renderingMode(.template)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                if let b = it.badge {
                    Text("\(b)")
                        .font(.system(size: 5, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(1.5)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: 3, y: 3)
                }
            }
            .frame(height: 13)
        } else {
            Text(String(it.name.prefix(1)))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 12)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.09)))
        }
    }

    /// 单项块：彩色大号百分比（或 ❌）+ logo/首字块
    @ViewBuilder
    private func block(_ it: StripItem) -> some View {
        VStack(spacing: 2) {
            if let u = it.used {
                let num = store.showRemaining ? 100 - u : u
                Text("\(num)%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(usageColor(u))
            } else {
                Text("❌").font(.system(size: 10))
            }
            ident(it)
        }
    }

    var body: some View {
        let horizontal = (store.stripEdge == .top || store.stripEdge == .bottom)
        let list = items.sorted { ($0.used ?? -1) > ($1.used ?? -1) }
        let tip = list.map { it in it.name + (it.used.map { " \($0)%" } ?? " ❌") }.joined(separator: " · ")
            + L(" · 点击展开仪表盘 · 拖到别的边可换吸", " · click to expand · drag to another edge")
        Group {
            if horizontal {
                HStack(spacing: 8) { ForEach(Array(list.enumerated()), id: \.offset) { _, it in block(it) } }
            } else {
                VStack(spacing: 6) { ForEach(Array(list.enumerated()), id: \.offset) { _, it in block(it) } }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 8)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .windowDrag()
        .help(tip)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    private var panel: NSPanel!
    private var placedInitially = false   // 完成"首次定位"前不保存位置、不落默认角
    private var cancellables: Set<AnyCancellable> = []

    init(store: Store) { self.store = store }

    func applicationDidFinishLaunching(_ note: Notification) {
        let host = NSHostingController(rootView: PanelRootView(store: store))
        host.sizingOptions = .preferredContentSize
        panel = NSPanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false // 拖动由 SwiftUI 的 windowDrag() 显式处理，避免双重移动
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 恢复上次位置
        if let saved = UserDefaults.standard.string(forKey: "panelFrame"),
           saved.contains("NSES") || saved.contains("{") {
            panel.setFrame(NSRectFromString(saved), display: true)
            if panel.frame.width > 50 { placedInitially = true }
        }
        panel.orderFrontRegardless()

        if !placedInitially {
            // SwiftUI 首次布局是异步的：先强制布局同步拿尺寸；拿不到就等首次 resize
            panel.layoutIfNeeded()
            host.view.layoutSubtreeIfNeeded()
            let fit = host.view.fittingSize
            if fit.width > 50, fit.height > 10 {
                panel.setContentSize(fit)
                placeTopRight()
            }
        }
        if !placedInitially {
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                guard let self, !self.placedInitially, let p = self.panel, p.frame.width > 50 else { return }
                self.placeTopRight()
            }
        }
        // 尺寸变化后归位：吸边条模式贴齐吸附边（条宽<50，老 guard 会拦掉必须放行）；仪表盘模式拉回可见区
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, self.placedInitially, let panel = self.panel else { return }
            if self.store.stripMode {
                if panel.frame.width > 5 { self.dockFlush() }
            } else if panel.frame.width > 50 {
                self.clampToVisible()
            }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            // 吸边条期间不保存位置（panelFrame 只记仪表盘展开位，供恢复）
            guard let self, self.placedInitially, !self.store.stripMode,
                  let panel = self.panel, panel.frame.width > 50 else { return }
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "panelFrame")
        }

        // 从吸边条恢复展开：回到收起前的仪表盘位置
        store.$stripMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] strip in
                guard let self, !strip, self.placedInitially, let panel = self.panel else { return }
                if let saved = UserDefaults.standard.string(forKey: "panelFrame"),
                   saved.contains("{"), NSRectFromString(saved).width > 50 {
                    panel.setFrame(NSRectFromString(saved), display: true)
                }
                self.clampToVisible()
            }
            .store(in: &cancellables)

        store.refreshAll()
        Timer.scheduledTimer(withTimeInterval: TimeInterval(Conf.shared.int("refreshIntervalSeconds", 180)), repeats: true) { [weak self] _ in
            self?.store.refreshAll()
        }
    }

    /// 窗口任意一边超出可见区时拉回来（展开/收起后调用）；吸边条模式改为贴齐当前边
    private func clampToVisible() {
        guard let screen = NSScreen.main else { return }
        if store.stripMode { dockFlush(); return }
        let v = screen.visibleFrame
        var f = panel.frame
        var changed = false
        if f.maxX > v.maxX - 24 { f.origin.x = v.maxX - 24 - f.width; changed = true }
        if f.maxY > v.maxY - 8 { f.origin.y = v.maxY - 8 - f.height; changed = true } // 顶部贴菜单栏下方向下生长
        if f.minY < v.minY { f.origin.y = v.minY; changed = true }
        if changed { panel.setFrame(f, display: true) }
    }

    /// 吸边条拖到新位置后调用：按鼠标落点最近的屏幕边重新吸附并持久化
    func stripDragEnded(mouse: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let v = screen?.visibleFrame, v.width > 0 else { return }
        let dists: [(DockEdge, CGFloat)] = [(.top, v.maxY - mouse.y), (.bottom, mouse.y - v.minY),
                                             (.left, mouse.x - v.minX), (.right, v.maxX - mouse.x)]
        if let e = dists.min(by: { $0.1 < $1.1 })?.0 {
            store.stripEdge = e
            UserDefaults.standard.set(e.rawValue, forKey: "stripEdge")
        }
        dockFlush()
    }

    /// 吸边条贴齐当前边：贴边方向 0 间距，沿边坐标保留并夹回可见区
    private func dockFlush() {
        guard let screen = NSScreen.main, let p = panel, p.frame.width > 5 else { return }
        let v = screen.visibleFrame
        var f = p.frame
        switch store.stripEdge {
        case .top: f.origin.y = v.maxY - f.height
        case .bottom: f.origin.y = v.minY
        case .left: f.origin.x = v.minX
        case .right: f.origin.x = v.maxX - f.width
        }
        if store.stripEdge == .top || store.stripEdge == .bottom {
            f.origin.x = min(max(f.origin.x, v.minX), max(v.minX, v.maxX - f.width))
        } else {
            f.origin.y = min(max(f.origin.y, v.minY), max(v.minY, v.maxY - f.height))
        }
        p.setFrame(f, display: true)
    }

    /// 贴屏幕可见区右上角（菜单栏/Dock 之下）
    private func placeTopRight() {
        placedInitially = true
        guard let screen = NSScreen.main else { return }
        var f = panel.frame
        f.origin = NSPoint(x: screen.visibleFrame.maxX - f.width - 24,
                           y: screen.visibleFrame.maxY - f.height - 8)
        panel.setFrame(f, display: true)
        print("[启动] panel=\(NSStringFromRect(panel.frame))  screen.visible=\(NSStringFromRect(screen.visibleFrame))")
        fflush(stdout)
    }
}

// MARK: - 入口（QUOTADOCK_RENDER=1 时离屏渲染面板 PNG 用于视觉检查，否则正常运行）

if ProcessInfo.processInfo.environment["QUOTADOCK_RENDER"] == "1" {
    _ = NSApplication.shared
    let store = Store()
    let mk = { (p5: Int, pw: Int) in LimitEntry(percentage: p5, usage: nil, currentValue: nil, nextResetTime: Date().timeIntervalSince1970 * 1000 + Double(pw) * 60_000) }
    store.keyQuotas = [
        KeyQuota(name: "周卡", keyTail: "J7Fk", quota: QuotaData(fiveHour: mk(45, 288), weekly: mk(1, 7 * 1440), tools: LimitEntry(percentage: 1, usage: 4000, currentValue: 9, nextResetTime: Date().timeIntervalSince1970 * 1000 + 30 * 1440 * 60_000), level: "max"), error: nil),
        KeyQuota(name: "新卡", keyTail: "PbJy", quota: QuotaData(fiveHour: mk(11, 115), weekly: mk(3, 4 * 1440), tools: nil, level: "max"), error: nil),
    ]
    store.extras = [
        ExtraService(name: "Codex Pro", value: "41%", detail: "周窗口 · 重置 5天21小时后", usedPercent: 41),
        ExtraService(name: "Kimi", value: "Allegretto", detail: "子瞻 · 已连接 · 无余额接口", usedPercent: nil),
        ExtraService(name: "MiMo", value: "更新 15:12", detail: "已用 63% · 剩余 37% · 重置 2026-10-13 · MiMo 进阶", usedPercent: 63),
        ExtraService(name: "CC racknerd", value: "更新 11:31", detail: "5h 37% · 周 5%", usedPercent: 37,
                     fiveBar: mk(37, 240), weekBar: mk(5, 7 * 1440)),
        ExtraService(name: "CC racknerd2", value: "⚠ 停更于 10/9 15:26", detail: "5h 6% · 周 1%", usedPercent: 6,
                     fiveBar: mk(6, 180), weekBar: mk(1, 3 * 1440), stale: true),
    ]
    store.lastUpdate = Date()
    if ProcessInfo.processInfo.environment["QUOTADOCK_STRIP"] == "1" {
        store.stripMode = true
        if let e = ProcessInfo.processInfo.environment["QUOTADOCK_EDGE"], let edge = DockEdge(rawValue: e) { store.stripEdge = edge }
    }
    let dark = ProcessInfo.processInfo.environment["QUOTADOCK_DARK"] == "1"
    let root = AnyView(PanelRootView(store: store, initiallyCollapsed: ProcessInfo.processInfo.environment["QUOTADOCK_STRIP"] == "1"))
    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // 先用任意高度布局一次，等 SwiftUI 完成布局后再量真实尺寸
    host.frame = NSRect(origin: .zero, size: NSSize(width: 336, height: 50))
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // rep 的 DPI 已带 2x 缩放，这里不能重复 scaleBy，否则内容 4 倍渲染溢出裁切
    // 面板底色模拟 popover 材质
    (dark ? NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1) : NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    host.displayIgnoringOpacity(host.bounds, in: NSGraphicsContext.current!)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUOTADOCK_OUT"] ?? "/tmp/glm-popover.png"))
    exit(0)
}

let app = NSApplication.shared
let store = Store()
let delegate = AppDelegate(store: store)
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不显示 Dock 图标
app.run()
