import XCTest
@testable import QuotaDockCore

// MARK: - 配置：字段级校验回退 + 热加载

final class ConfigurationStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qd-cfg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func writeConfig(_ json: String) -> URL {
        let url = dir.appendingPathComponent("config.json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: 字段级清洗

    func testSanitizeClampsBadValues() {
        let cfg = AppConfiguration(root: [
            "language": "fr",
            "timezone": "Mars/Olympus",
            "refreshIntervalSeconds": 5,
            "thresholds": ["yellow": 90, "red": 40],
        ])
        XCTAssertEqual(cfg.language, "zh")
        XCTAssertEqual(cfg.timezoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(cfg.refreshInterval, 30)
        XCTAssertEqual(cfg.thresholds.yellow, 60)
        XCTAssertEqual(cfg.thresholds.red, 85)
        XCTAssertTrue(cfg.issues.contains { $0.field == "language" })
        XCTAssertTrue(cfg.issues.contains { $0.field == "thresholds" })
        XCTAssertTrue(cfg.issues.contains { $0.field == "refreshIntervalSeconds" })
    }

    func testSanitizeValidConfigHasNoIssues() {
        let cfg = AppConfiguration(root: [
            "language": "en",
            "timezone": "America/New_York",
            "refreshIntervalSeconds": 240,
            "thresholds": ["yellow": 50, "red": 80],
        ])
        XCTAssertTrue(cfg.issues.isEmpty)
        XCTAssertEqual(cfg.language, "en")
        XCTAssertEqual(cfg.refreshInterval, 240)
    }

    func testSanitizeDropsUnsafeSSHConfig() {
        let cfg = AppConfiguration(root: [
            "claudeCode": ["servers": [
                // host 本身是注入形态 → 整台丢弃
                ["host": "my-vps; rm -rf /", "paths": ["/root/.claude.json"]],
                // host 合法：user 与 paths 非法 → 字段清洗后保留
                ["host": "good-host", "user": "claude;reboot",
                 "paths": ["/root/.claude.json", "/tmp/x'$(id)"]],
                ["host": "ok-host", "user": "claude", "sshPort": "99999",
                 "paths": ["/home/claude/.claude.json"]],
            ]],
        ])
        let servers = cfg["claudeCode"]?.list("servers") ?? []
        XCTAssertEqual(servers.count, 2, "注入形态的 host 必须被丢弃，合法 host 只清洗非法字段")
        XCTAssertEqual(servers[0].str("host"), "good-host")
        XCTAssertEqual(servers[0].str("user"), "", "非法 user 清空=回退 SSH 登录用户")
        XCTAssertEqual(servers[0].strList("paths"), ["/root/.claude.json"], "含引号的路径必须被过滤")
        XCTAssertEqual(servers[1].str("host"), "ok-host")
        XCTAssertEqual(servers[1].str("sshPort"), "", "越界 sshPort 清空=默认 22")
        XCTAssertTrue(cfg.issues.contains { $0.field.contains("host") })
        XCTAssertTrue(cfg.issues.contains { $0.field.contains("user") })
        XCTAssertTrue(cfg.issues.contains { $0.field.contains("paths") })
    }

    func testSanitizeDropsShortZhipuKeys() {
        let cfg = AppConfiguration(root: [
            "zhipu": ["keys": [["name": "ok", "key": "12345678.abcd"],
                               ["name": "bad", "key": "short"]]],
        ])
        XCTAssertEqual(cfg["zhipu"]?.list("keys").count, 1)
        XCTAssertTrue(cfg.issues.contains { $0.field == "zhipu.keys" })
    }

    func testPerSourceIntervalFloor() {
        XCTAssertEqual(AppConfiguration(root: [:]).interval(for: .codex), 180)
        XCTAssertEqual(AppConfiguration(root: [:]).interval(for: .claudeCode), 600)
        XCTAssertEqual(AppConfiguration(root: ["kimi": ["refreshIntervalSeconds": 10]]).interval(for: .kimi), 30)
    }

    // MARK: 热加载

    func testHotReloadAppliesValidChanges() throws {
        let url = writeConfig(#"{"language":"zh","refreshIntervalSeconds":180}"#)
        let store = ConfigurationStore(path: url)
        XCTAssertEqual(store.currentSnapshot().refreshInterval, 180)

        writeConfig(#"{"language":"zh","refreshIntervalSeconds":300}"#)
        XCTAssertTrue(store.reloadIfChanged())
        XCTAssertEqual(store.currentSnapshot().refreshInterval, 300)
        XCTAssertEqual(store.currentSnapshot().revision, 1)
    }

    /// 内容没变（重写同样 JSON）：不 bump revision
    func testHotReloadIgnoresUnchangedContent() throws {
        let url = writeConfig(#"{"language":"zh"}"#)
        let store = ConfigurationStore(path: url)
        writeConfig(#"{"language":"zh"}"#)
        XCTAssertFalse(store.reloadIfChanged())
        XCTAssertEqual(store.currentSnapshot().revision, 0)
    }

    /// paths 配置兼容字符串数组与 [{path:}] 字典数组两种形态
    func testPathsDualFormat() {
        let strings = AppConfiguration(root: [
            "claudeCode": ["servers": [["host": "a", "paths": ["/root/.claude.json"]]]],
        ])
        let dicts = AppConfiguration(root: [
            "claudeCode": ["servers": [["host": "a", "paths": [["path": "/root/.claude.json"]]]]],
        ])
        XCTAssertEqual(strings["claudeCode"]?.list("servers").first?.strList("paths"),
                       ["/root/.claude.json"])
        XCTAssertEqual(dicts["claudeCode"]?.list("servers").first?.strList("paths"),
                       ["/root/.claude.json"])
    }

    /// 坏 JSON：保留上一份有效配置 + 暴露问题
    func testHotReloadKeepsPreviousOnBrokenFile() throws {
        let url = writeConfig(#"{"language":"zh","refreshIntervalSeconds":180}"#)
        let store = ConfigurationStore(path: url)
        writeConfig(#"{"language": "#)
        XCTAssertFalse(store.reloadIfChanged())
        XCTAssertEqual(store.currentSnapshot().refreshInterval, 180, "保留旧配置")
        XCTAssertEqual(store.currentSnapshot().revision, 0)
        XCTAssertFalse(store.fileIssues.isEmpty)
    }

    /// 坏文件修复后恢复正常并清掉 fileIssues
    func testHotReloadRecoversAfterFix() throws {
        let url = writeConfig(#"{"bad"#)
        let store = ConfigurationStore(path: url)
        XCTAssertFalse(store.fileIssues.isEmpty)
        writeConfig(#"{"language":"en"}"#)
        XCTAssertTrue(store.reloadIfChanged())
        XCTAssertTrue(store.fileIssues.isEmpty)
        XCTAssertEqual(store.currentSnapshot().language, "en")
    }
}
