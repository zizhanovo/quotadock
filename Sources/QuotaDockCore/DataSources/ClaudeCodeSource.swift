import Foundation

// MARK: - Claude Code 数据源（远程 VPS + 本机两种模式）

/// 远程：优先 SSH 在服务器上跑 `claude -p /usage` 刷新缓存（凭据/流量都留在 VPS），再只读
/// cachedUsageUtilization。可配置 claudeCode.refreshUsage=false 回到纯被动。
/// 本机：claudeCode.local.enabled=true 时多一个 cc:local 身份，best-effort 跑本地
/// `claude -p /usage` 后读 ~/.claude.json——CC 切到本机跑时不再需要 SSH。
/// 多账号接力：local.extraProfiles 可挂更多本机 profile（如 et 的
/// ~/.claude-profiles/et/.claude.json），每个一条被动行（extras 纯被动，不拉探针）。
/// 安全：host 走 argv 单独参数；远端命令里的 user/paths 一律白名单校验 + 单引号包裹，
/// 不拼接任何未校验的 shell 片段。SSH 失败是临时故障（保留最近成功值），不写 skip。
public struct ClaudeCodeSource: QuotaSource {
    public let id = SourceID.claudeCode

    /// 本机身份 key（host 是远端身份主键，local 不会与之冲突）
    static let localKey = "cc:local"
    static let localPrefix = "cc:local:"
    /// 本机 claude -p /usage 刷新上限：冷启动 + API 往返，15s 的请求超时不够用
    static let localRefreshTimeout: TimeInterval = 120

    public init() {}

    static func isLocalEnabled(_ app: AppConfiguration) -> Bool {
        app["claudeCode"]?["local"]?.bool("enabled", false) ?? false
    }

    /// 额外本机 profile：[{name, path}]；与默认路径相同的条目去重
    /// refreshUsage/claudePath 是 profile 级可选项：该号有独立启动器（二进制路径被 Surge
    /// 进程规则钉住出口）时，探针必须用它自己的二进制 + CLAUDE_CONFIG_DIR，默认不探。
    static func extraProfiles(_ app: AppConfiguration)
        -> [(name: String, path: String, refreshUsage: Bool, claudePath: String)] {
        let basePath = app["claudeCode"]?["local"]?.path("path", "~/.claude.json") ?? "~/.claude.json"
        return (app["claudeCode"]?["local"]?.list("extraProfiles") ?? []).compactMap { p in
            let path = p.path("path", "")
            guard !path.isEmpty, path != basePath else { return nil }
            return (p.str("name", "profile"), path, p.bool("refreshUsage", false), p.path("claudePath", ""))
        }
    }

    /// 探针子进程环境：继承本进程环境，补 USER（claude 凭据钥匙串按 $USER 取账号，缺了
    /// 会静默退化成无订阅态的 "Total cost" 输出且不写缓存）；configDir 非空则指向该
    /// profile，空则清掉继承来的 CLAUDE_CONFIG_DIR 以免读错号。
    static func probeEnvironment(base: [String: String], configDir: String?) -> [String: String] {
        var env = base
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if let configDir, !configDir.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = configDir
        } else {
            env["CLAUDE_CONFIG_DIR"] = nil
        }
        return env
    }

    /// 本机是否主动跑 `claude -p /usage`：local.refreshUsage 优先，缺省继承全局
    /// refreshUsage。代理只配在终端会话里的环境，launchd 无代理变量，应显式关掉
    /// 改为纯被动（读真实会话/手动 /usage 留下的缓存）。
    static func localRefreshUsage(_ app: AppConfiguration) -> Bool {
        guard let local = app["claudeCode"]?["local"] else { return false }
        return local.bool("refreshUsage", app["claudeCode"]?.bool("refreshUsage", true) ?? true)
    }

    public func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity] {
        var ids = (configuration["claudeCode"]?.list("servers") ?? [])
            .compactMap { srv -> SourceIdentity? in
                let host = srv.str("host")
                // host "local" 是本机身份的保留键，避免 cc:local 身份冲突串路
                guard ShellSafety.isSafeSSHHost(host), host != "local" else { return nil }
                let label = srv.str("name", host)
                return SourceIdentity(source: .claudeCode, key: "cc:\(host)",
                                      displayName: "CC \(label)")
            }
        if Self.isLocalEnabled(configuration) {
            let local = configuration["claudeCode"]?["local"]
            ids.append(SourceIdentity(source: .claudeCode, key: Self.localKey,
                                      displayName: local?.str("name", L("CC 本机", "CC local")) ?? L("CC 本机", "CC local")))
            for p in Self.extraProfiles(configuration) {
                ids.append(SourceIdentity(source: .claudeCode, key: "\(Self.localPrefix)\(p.name)",
                                          displayName: "CC \(p.name)"))
            }
        }
        return ids
    }

    public func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
        let key = configuration.identity.key
        if key == Self.localKey {
            let path = configuration.app["claudeCode"]?["local"]?.path("path", "~/.claude.json") ?? "~/.claude.json"
            return await fetchLocal(configuration: configuration, path: path,
                                    refresh: Self.localRefreshUsage(configuration.app)
                                        ? Probe(bin: Self.resolveClaudeBin(configuration.app), configDir: nil) : nil,
                                    cancellation: cancellation)
        }
        if key.hasPrefix(Self.localPrefix) {
            let name = String(key.dropFirst(Self.localPrefix.count))
            guard let p = Self.extraProfiles(configuration.app).first(where: { $0.name == name }) else {
                return SourceResult(identity: configuration.identity, snapshot: nil,
                                    status: .noDataYet(hint: L("profile 配置缺失", "profile config missing")))
            }
            // extras 默认纯被动：profile 可能对应任意启动器/链路。显式 refreshUsage + claudePath
            // 才探——用该号自己的二进制（出口按进程路径钉定）和 CLAUDE_CONFIG_DIR。
            var probe: Probe?
            if p.refreshUsage {
                let bin = (p.claudePath as NSString).expandingTildeInPath
                let dir = ((p.path as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
                probe = Probe(bin: !p.claudePath.isEmpty && FileManager.default.isExecutableFile(atPath: bin) ? bin : nil,
                              configDir: dir)
            }
            return await fetchLocal(configuration: configuration, path: p.path,
                                    refresh: probe, cancellation: cancellation)
        }
        return await fetchRemote(configuration: configuration, cancellation: cancellation)
    }

    // MARK: 远程 VPS（SSH）

    private func fetchRemote(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
        let identity = configuration.identity
        // 从身份 key 反查服务器配置（host 是身份主键的一部分）
        let host = String(identity.key.dropFirst("cc:".count))
        guard let server = configuration.app["claudeCode"]?.list("servers").first(where: {
            $0.str("host") == host && ShellSafety.isSafeSSHHost($0.str("host"))
        }) else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("服务器配置缺失或 host 非法", "server config missing or host invalid")))
        }
        if cancellation.isCancelled {
            return SourceResult(identity: identity, snapshot: nil, status: .networkError("cancelled"))
        }

        let sshPort = server.str("sshPort", "")
        let portArgs = sshPort.isEmpty ? [] : ["-p", sshPort]
        let ccfg = configuration.app["claudeCode"]
        let connectTimeout = ccfg?.int("sshConnectTimeout", 10) ?? 10
        var args = ["-o", "ConnectTimeout=\(connectTimeout)", "-o", "BatchMode=yes"]
        if ccfg?.bool("sshMultiplexing", true) ?? true {
            args += ["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/quotadock-ssh-%C", "-o", "ControlPersist=1800"]
        }
        let cmd: String
        do {
            cmd = try Self.buildRemoteCommand(server: server,
                                              refreshUsage: ccfg?.bool("refreshUsage", true) ?? true)
        } catch {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .invalidPayload(diagnostic: "\(error)"))
        }

        let (code, out) = await Self.runSSH(args: args + portArgs + [host, cmd])
        guard code == 0,
              let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .networkError(L("SSH 失败（网络/跳板?）", "SSH failed")))
        }
        guard let u = obj["u"] as? [String: Any] else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("尚无使用缓存", "no usage cache yet")))
        }
        return Self.usageResult(u: u, identity: identity)
    }

    // MARK: 本机（读 ~/.claude.json）

    struct Probe { let bin: String?; let configDir: String? }

    /// 本机模式：best-effort 跑 `claude -p /usage` 刷新缓存（找不到 CLI 就跳过，靠真实
    /// 会话自然更新），再读本地 ~/.claude.json。缓存格式与远端一致，解析共用 usageResult。

    private func fetchLocal(configuration: SourceConfiguration, path: String,
                            refresh: Probe?, cancellation: CancellationToken) async -> SourceResult {
        let identity = configuration.identity
        if cancellation.isCancelled {
            return SourceResult(identity: identity, snapshot: nil, status: .networkError("cancelled"))
        }
        if let refresh {
            if let bin = refresh.bin {
                let env = Self.probeEnvironment(base: ProcessInfo.processInfo.environment,
                                                configDir: refresh.configDir)
                let run = await Subprocess.run(bin: bin, args: ["-p", "/usage"],
                                               timeout: Self.localRefreshTimeout, environment: env)
                if cancellation.isCancelled {
                    return SourceResult(identity: identity, snapshot: nil, status: .networkError("cancelled"))
                }
                if run.code != 0 {
                    Log.warn("cc 本机刷新失败：退出码 \(run.code)\(run.timedOut ? "（超时）" : "")")
                }
            } else {
                Log.warn("cc 本机刷新跳过：未找到 claude CLI（可配 claudeCode.local.claudePath）")
            }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let u = obj["cachedUsageUtilization"] as? [String: Any] else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("本机用量缓存缺失（\(path)），跑一次该号的 Claude Code",
                                                           "no local usage cache (\(path)); run that profile's Claude Code once")))
        }
        return Self.usageResult(u: u, identity: identity)
    }

    /// claudePath 显式配置优先；否则按常见安装位寻找（launchd 的 PATH 里没有用户级目录）
    static func resolveClaudeBin(_ app: AppConfiguration) -> String? {
        let configured = app["claudeCode"]?["local"]?.path("claudePath", "") ?? ""
        let candidates = configured.isEmpty
            ? ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            : [configured]
        for c in candidates {
            let p = (c as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// cachedUsageUtilization 对象 → 快照（远端 SSH 输出与本机文件共用）。
    /// {"fetchedAtMs":…, "utilization": {"five_hour": {"utilization":…, "resets_at":…}, "seven_day": …}}
    static func usageResult(u: [String: Any], identity: SourceIdentity) -> SourceResult {
        guard let util = u["utilization"] as? [String: Any],
              let h5 = util["five_hour"] as? [String: Any],
              let w7 = util["seven_day"] as? [String: Any],
              let p5 = (h5["utilization"] as? NSNumber)?.intValue,
              let p7 = (w7["utilization"] as? NSNumber)?.intValue else {
            return SourceResult(identity: identity, snapshot: nil,
                                status: .noDataYet(hint: L("尚无使用缓存", "no usage cache yet")))
        }
        let fetched = Date(timeIntervalSince1970: ((u["fetchedAtMs"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        func resetMs(_ d: [String: Any]) -> Double? {
            guard let s = d["resets_at"] as? String,
                  let t = isoDate(s) ?? isoDate(s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression))
            else { return nil }
            return t.timeIntervalSince1970 * 1000
        }
        let top = max(p5, p7)
        let stale = Date().timeIntervalSince(fetched) > FreshnessPolicy.usageSnapshotStaleAfter
        let snapshot = QuotaSnapshot(
            primaryUsedPercent: top,
            fiveHour: LimitEntry(percentage: p5, nextResetTime: resetMs(h5)),
            weekly: LimitEntry(percentage: p7, nextResetTime: resetMs(w7)),
            detail: "5h \(p5)% · \(L("周", "wk")) \(p7)%",
            stale: stale,
            meta: [:]
        )
        return SourceResult(identity: identity, snapshot: snapshot, status: .success, observedAt: fetched)
    }

    /// 远端命令构建（纯函数可测）。user/paths 经白名单校验后单引号包裹；
    /// paths 兼容字符串数组与 [{path:}] 字典数组两种配置形态。
    static func buildRemoteCommand(server: ConfigSection, refreshUsage: Bool) throws -> String {
        var paths = server.strList("paths").filter { !$0.isEmpty }
        if paths.isEmpty { paths = ["/home/claude/.claude.json", "/root/.claude.json"] }
        let pyPaths = try paths.map { try ShellSafety.singleQuoted($0) }.joined(separator: ",")
        var prelude = ""
        if refreshUsage {
            let runAs = server.str("user", "")   // 空 = SSH 登录用户（通常是 root）
            let claudeCmd = runAs.isEmpty
                ? "claude -p /usage"
                : "sudo -u \(try ShellSafety.singleQuoted(runAs)) -n claude -p /usage"
            prelude = "\(claudeCmd) >/dev/null 2>&1; "
        }
        // 多路径取快照最新的那份（fetchedAtMs 最大）
        return prelude + "python3 -c \"import json,os\nc=[]\nfor p in [\(pyPaths)]:\n if os.path.exists(p):\n  d=json.load(open(p));u=d.get('cachedUsageUtilization')\n  if u:c.append((u.get('fetchedAtMs',0),(d.get('oauthAccount') or {}).get('emailAddress'),u))\nb=max(c) if c else None\nprint(json.dumps({'email':(b[1] if b else None),'u':(b[2] if b else None)}))\""
    }

    /// 跑一条 ssh 命令（全局队列 + continuation 包装，ConnectTimeout 兜底耗时）
    static func runSSH(args: [String]) async -> (code: Int, out: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = args
                let outPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = Pipe()
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: (-1, ""))
                    return
                }
                p.waitUntilExit()
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (Int(p.terminationStatus), out))
            }
        }
    }
}
