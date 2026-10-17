import XCTest
@testable import QuotaDockCore

// MARK: - ClaudeCodeSource 测试：本机模式身份/抓取 + 共用解析

final class ClaudeCodeSourceTests: XCTestCase {
    private let localIdentity = SourceIdentity(source: .claudeCode, key: "cc:local", displayName: "CC 本机")

    private func config(_ claudeCode: [String: Any]) -> AppConfiguration {
        AppConfiguration(root: ["claudeCode": claudeCode])
    }

    private func localConfig(path: String) -> AppConfiguration {
        // refreshUsage=false：测试环境不真正拉起 claude CLI
        config(["local": ["enabled": true, "path": path],
                "refreshUsage": false])
    }

    /// 与真实 ~/.claude.json 同构的最小缓存（数字取自实际样本）
    private func writeCache() throws -> String {
        let cache: [String: Any] = [
            "cachedUsageUtilization": [
                "fetchedAtMs": 1_792_043_212_782,
                "utilization": [
                    "five_hour": ["utilization": 10, "resets_at": "2026-10-15T10:40:00.441672+00:00"],
                    "seven_day": ["utilization": 57, "resets_at": "2026-10-19T00:00:00.441692+00:00"],
                ],
            ]
        ]
        let path = NSTemporaryDirectory() + "quotadock-cc-test-\(UUID().uuidString).json"
        try JSONSerialization.data(withJSONObject: cache).write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func fetch(_ cfg: AppConfiguration) async -> SourceResult {
        await ClaudeCodeSource().fetch(
            configuration: SourceConfiguration(identity: localIdentity, app: cfg,
                                               refreshInterval: 600, timeout: 15),
            cancellation: CancellationToken())
    }

    // 身份注册

    func testLocalIdentityOnlyWhenEnabled() {
        let off = ClaudeCodeSource().identities(configuration: config(["servers": [["host": "vps-a"]]]),
                                                includeSkipped: false)
        XCTAssertEqual(off.map { $0.key }, ["cc:vps-a"])   // 默认不开本机
        let on = ClaudeCodeSource().identities(
            configuration: config(["servers": [["host": "vps-a"]], "local": ["enabled": true]]),
            includeSkipped: false)
        XCTAssertEqual(on.map { $0.key }, ["cc:vps-a", ClaudeCodeSource.localKey])
        XCTAssertEqual(on.last?.displayName, "CC 本机")
    }

    // 本机抓取

    func testLocalFetchReadsLocalCache() async throws {
        let path = try writeCache()
        let r = await fetch(localConfig(path: path))
        XCTAssertEqual(r.status, .success)
        let snap = try XCTUnwrap(r.snapshot)
        XCTAssertEqual(snap.primaryUsedPercent, 57)   // 主值 = 最紧张窗口
        XCTAssertEqual(snap.fiveHour?.percentage, 10)
        XCTAssertEqual(snap.weekly?.percentage, 57)
        XCTAssertEqual(r.observedAt, Date(timeIntervalSince1970: 1_792_043_212.782))
        XCTAssertEqual(snap.fiveHour?.nextResetTime, isoDate("2026-10-15T10:40:00.441672+00:00")!.timeIntervalSince1970 * 1000)
    }

    func testLocalFetchMissingFileIsNoDataYet() async {
        let r = await fetch(localConfig(path: "/no/such/.claude.json"))
        guard case .noDataYet = r.status else {
            return XCTFail("expected noDataYet for missing local cache")
        }
        XCTAssertNil(r.snapshot)
    }

    func testLocalFetchWithoutCacheKeyIsNoDataYet() async throws {
        let path = NSTemporaryDirectory() + "quotadock-cc-empty-\(UUID().uuidString).json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let r = await fetch(localConfig(path: path))
        guard case .noDataYet = r.status else {
            return XCTFail("expected noDataYet when cachedUsageUtilization absent")
        }
    }

    // 多账号 profiles（接力：et 等第二本机槽位）

    func testExtraProfilesIdentitiesAndDedupe() {
        let cfg = config(["local": ["enabled": true,
                                     "extraProfiles": [["name": "et", "path": "~/.claude-profiles/et/.claude.json"],
                                                        ["name": "dup", "path": "~/.claude.json"]]]])
        let ids = ClaudeCodeSource().identities(configuration: cfg, includeSkipped: false)
        XCTAssertEqual(ids.map { $0.key }, ["cc:local", "cc:local:et"])   // 与默认路径相同的 dup 去重
        XCTAssertEqual(ids.last?.displayName, "CC et")
    }

    func testExtraProfileFetchReadsItsOwnCache() async throws {
        let path = try writeCache()
        let cfg = config(["local": ["enabled": true, "refreshUsage": false,
                                     "extraProfiles": [["name": "et", "path": path]]]])
        let r = await ClaudeCodeSource().fetch(configuration: SourceConfiguration(
            identity: SourceIdentity(source: .claudeCode, key: "cc:local:et", displayName: "CC et"),
            app: cfg, refreshInterval: 600, timeout: 15), cancellation: CancellationToken())
        XCTAssertEqual(r.status, .success)
        XCTAssertEqual(r.snapshot?.primaryUsedPercent, 57)
    }

    // 探针环境：缺 USER 时钥匙串取不到订阅凭据 → 静默不写缓存；configDir 决定读写哪个号

    func testProbeEnvironmentFillsUserAndDropsInheritedConfigDir() {
        let env = ClaudeCodeSource.probeEnvironment(
            base: ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/x/et"], configDir: nil)
        XCTAssertEqual(env["USER"], NSUserName())
        XCTAssertEqual(env["HOME"], NSHomeDirectory())
        XCTAssertNil(env["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testProbeEnvironmentPointsAtProfileDir() {
        let env = ClaudeCodeSource.probeEnvironment(base: ["USER": "u"], configDir: "/p/et")
        XCTAssertEqual(env["USER"], "u")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/p/et")
    }

    func testExtraProfileProbeIsOptIn() {
        let cfg = config(["local": ["enabled": true, "extraProfiles": [
            ["name": "a", "path": "/a/.claude.json"],
            ["name": "b", "path": "/b/.claude.json", "refreshUsage": true, "claudePath": "/b/claude"]]]])
        let ps = ClaudeCodeSource.extraProfiles(cfg)
        XCTAssertEqual(ps.map { $0.refreshUsage }, [false, true])
        XCTAssertEqual(ps.last?.claudePath, "/b/claude")
    }

    // 共用解析（远端 SSH 输出与本机文件都走这里）

    func testUsageResultParsesCachedUsageObject() throws {
        let u: [String: Any] = [
            "fetchedAtMs": Date().timeIntervalSince1970 * 1000 - 60_000,
            "utilization": [
                "five_hour": ["utilization": 10, "resets_at": "2026-10-15T10:40:00.441672+00:00"],
                "seven_day": ["utilization": 57, "resets_at": "2026-10-19T00:00:00.441692+00:00"],
            ],
        ]
        let r = ClaudeCodeSource.usageResult(u: u, identity: localIdentity)
        XCTAssertEqual(r.status, .success)
        XCTAssertEqual(r.snapshot?.primaryUsedPercent, 57)
        XCTAssertFalse(r.snapshot?.stale ?? true)
    }

    func testUsageResultMalformedIsNoDataYet() {
        let r = ClaudeCodeSource.usageResult(u: ["fetchedAtMs": 0], identity: localIdentity)
        guard case .noDataYet = r.status else {
            return XCTFail("expected noDataYet for malformed usage object")
        }
    }

    // claude CLI 定位

    func testResolveClaudeBinPrefersConfigured() {
        let cfg = config(["local": ["claudePath": "/usr/bin/true"]])
        XCTAssertEqual(ClaudeCodeSource.resolveClaudeBin(cfg), "/usr/bin/true")
        let missing = config(["local": ["claudePath": "/no/such/claude"]])
        XCTAssertNil(ClaudeCodeSource.resolveClaudeBin(missing))
    }

    // 本机刷新开关：local.refreshUsage 优先，缺省继承全局

    func testLocalRefreshUsageOverride() {
        // 未配置 local → 不刷新（本机模式都没开，谈不上刷新）
        XCTAssertFalse(ClaudeCodeSource.localRefreshUsage(config(["refreshUsage": true])))
        // 缺省继承全局 refreshUsage
        XCTAssertTrue(ClaudeCodeSource.localRefreshUsage(config(["local": ["enabled": true],
                                                                 "refreshUsage": true])))
        // local 显式关掉：代理只配在终端会话、launchd 无代理变量的环境
        XCTAssertFalse(ClaudeCodeSource.localRefreshUsage(config(["local": ["enabled": true, "refreshUsage": false],
                                                                  "refreshUsage": true])))
        // local 显式开启可覆盖全局关闭
        XCTAssertTrue(ClaudeCodeSource.localRefreshUsage(config(["local": ["enabled": true, "refreshUsage": true],
                                                                 "refreshUsage": false])))
    }
}
