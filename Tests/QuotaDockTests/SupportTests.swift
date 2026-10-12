import XCTest
@testable import QuotaDockCore

// MARK: - Shell 安全 + CC 远端命令 + 新鲜度策略 + 时间格式化

final class ShellSafetyTests: XCTestCase {

    func testHostValidation() {
        XCTAssertTrue(ShellSafety.isSafeSSHHost("my-vps.example.com"))
        XCTAssertTrue(ShellSafety.isSafeSSHHost("192.168.1.10"))
        XCTAssertTrue(ShellSafety.isSafeSSHHost("user@host"))
        XCTAssertFalse(ShellSafety.isSafeSSHHost(""))
        XCTAssertFalse(ShellSafety.isSafeSSHHost("host; rm -rf /"))
        XCTAssertFalse(ShellSafety.isSafeSSHHost("host'quote"))
        XCTAssertFalse(ShellSafety.isSafeSSHHost("host with space"))
    }

    func testUsernameValidation() {
        XCTAssertTrue(ShellSafety.isSafeUnixUsername("claude"))
        XCTAssertTrue(ShellSafety.isSafeUnixUsername("_svc"))
        XCTAssertTrue(ShellSafety.isSafeUnixUsername("a-b_c2"))
        XCTAssertFalse(ShellSafety.isSafeUnixUsername("Upper"))
        XCTAssertFalse(ShellSafety.isSafeUnixUsername("1abc"))
        XCTAssertFalse(ShellSafety.isSafeUnixUsername("x;sudo"))
        XCTAssertFalse(ShellSafety.isSafeUnixUsername(""))
    }

    func testRemotePathValidation() {
        XCTAssertTrue(ShellSafety.isSafeRemotePath("/root/.claude.json"))
        XCTAssertTrue(ShellSafety.isSafeRemotePath("/home/claude/.claude.json"))
        XCTAssertFalse(ShellSafety.isSafeRemotePath("relative/path"))
        XCTAssertFalse(ShellSafety.isSafeRemotePath("/tmp/x'$(id)"))
        XCTAssertFalse(ShellSafety.isSafeRemotePath("/tmp/a b"))
        XCTAssertFalse(ShellSafety.isSafeRemotePath("/tmp/$(pwd)"))
    }

    func testSingleQuotedThrowsOnUnsafe() {
        XCTAssertThrowsError(try ShellSafety.singleQuoted("/x'$(id)"))
        XCTAssertNoThrow(try ShellSafety.singleQuoted("/root/.claude.json"))
        XCTAssertEqual(try ShellSafety.singleQuoted("/root/.claude.json"), "'/root/.claude.json'")
    }
}

final class ClaudeCodeCommandTests: XCTestCase {

    private func server(_ obj: [String: Any]) -> ConfigSection { ConfigSection(obj: obj) }

    /// 默认路径 + 刷新 + sudo 用户：路径/用户名都被单引号包裹
    func testBuildRemoteCommandDefaults() throws {
        let cmd = try ClaudeCodeSource.buildRemoteCommand(server: server([:]), refreshUsage: true)
        XCTAssertTrue(cmd.hasPrefix("claude -p /usage >/dev/null 2>&1; python3 -c "))
        XCTAssertTrue(cmd.contains("'/home/claude/.claude.json'"))
        XCTAssertTrue(cmd.contains("'/root/.claude.json'"))
    }

    func testBuildRemoteCommandWithUserAndPaths() throws {
        let cmd = try ClaudeCodeSource.buildRemoteCommand(
            server: server(["user": "claude", "paths": [["path": "/srv/claude/.claude.json"]]]),
            refreshUsage: true)
        XCTAssertTrue(cmd.contains("sudo -u 'claude' -n claude -p /usage"))
        XCTAssertTrue(cmd.contains("'/srv/claude/.claude.json'"))
        XCTAssertFalse(cmd.contains("/home/claude"))
    }

    func testBuildRemoteCommandPassiveMode() throws {
        let cmd = try ClaudeCodeSource.buildRemoteCommand(server: server([:]), refreshUsage: false)
        XCTAssertTrue(cmd.hasPrefix("python3 -c "))
    }

    /// 未清洗的配置直接进 builder 必须抛错（纵深防御：正常路径已在 ConfigurationStore 拦截）
    func testBuildRemoteCommandRejectsInjection() {
        XCTAssertThrowsError(try ClaudeCodeSource.buildRemoteCommand(
            server: server(["paths": [["path": "/x'$(reboot)"]]]), refreshUsage: false))
        XCTAssertThrowsError(try ClaudeCodeSource.buildRemoteCommand(
            server: server(["user": "u;halt"]), refreshUsage: true))
    }

    func testIdentitiesRequireSafeHost() {
        let cfg = AppConfiguration(root: [
            "claudeCode": ["servers": [
                ["host": "vps-a"],
                ["host": "bad host"],
            ]],
        ])
        let ids = ClaudeCodeSource().identities(configuration: cfg, includeSkipped: false)
        XCTAssertEqual(ids.map { $0.key }, ["cc:vps-a"])
        XCTAssertEqual(ids.first?.displayName, "CC vps-a")
    }
}

final class FreshnessPolicyTests: XCTestCase {

    func testClassify() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(FreshnessPolicy.classify(lastGoodAt: nil, now: now), .noneYet)
        XCTAssertEqual(FreshnessPolicy.classify(lastGoodAt: now.addingTimeInterval(-60), now: now),
                       .cached(now.addingTimeInterval(-60)))
        XCTAssertEqual(FreshnessPolicy.classify(lastGoodAt: now.addingTimeInterval(-90000), now: now),
                       .stale(now.addingTimeInterval(-90000)))
    }

    /// 剩余/已用切换只改数字：颜色与排序语义不随模式反转
    func testPercentDisplaySemantics() {
        XCTAssertEqual(FreshnessPolicy.percent(forDisplay: 70, showRemaining: false), 70)
        XCTAssertEqual(FreshnessPolicy.percent(forDisplay: 70, showRemaining: true), 30)
        XCTAssertEqual(FreshnessPolicy.percent(forDisplay: 100, showRemaining: true), 0)
    }
}

final class TimeFormattingTests: XCTestCase {

    func testISODateParsing() {
        XCTAssertNotNil(isoDate("2026-10-12T08:30:00Z"))
        XCTAssertNotNil(isoDate("2026-10-12T08:30:00.123Z"))
        XCTAssertNil(isoDate("not a date"))
    }

    func testShortCountdownBoundaries() {
        let past = (Date().timeIntervalSince1970 - 60) * 1000
        XCTAssertEqual(shortCountdown(past), L("已到点", "due"))
        XCTAssertEqual(shortCountdown(nil), "-")
        let future = (Date().timeIntervalSince1970 + 30 * 60) * 1000
        let s = shortCountdown(future)
        XCTAssertTrue(s.contains("30") || s.contains("31"), "分钟取整可以向上：\(s)")
    }
}
