import Foundation

// MARK: - Claude Code（远程 VPS）数据源

/// 优先 SSH 在服务器上跑 `claude -p /usage` 刷新缓存（凭据/流量都留在 VPS），再只读
/// cachedUsageUtilization。可配置 claudeCode.refreshUsage=false 回到纯被动。
/// 安全：host 走 argv 单独参数；远端命令里的 user/paths 一律白名单校验 + 单引号包裹，
/// 不拼接任何未校验的 shell 片段。SSH 失败是临时故障（保留最近成功值），不写 skip。
public struct ClaudeCodeSource: QuotaSource {
    public let id = SourceID.claudeCode

    public init() {}

    public func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity] {
        (configuration["claudeCode"]?.list("servers") ?? [])
            .compactMap { srv -> SourceIdentity? in
                let host = srv.str("host")
                guard ShellSafety.isSafeSSHHost(host) else { return nil }
                let label = srv.str("name", host)
                return SourceIdentity(source: .claudeCode, key: "cc:\(host)",
                                      displayName: "CC \(label)")
            }
    }

    public func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
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
        guard let u = obj["u"] as? [String: Any],
              let util = u["utilization"] as? [String: Any],
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
        let stale = Date().timeIntervalSince(fetched) > FreshnessPolicy.staleAfter
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
