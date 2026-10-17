import XCTest
@testable import QuotaDockCore

// MARK: - MagpieSource 解析测试（`magpie quota cursor --json` 的真实输出形态）

final class MagpieSourceTests: XCTestCase {
    private let identity = SourceIdentity(source: .magpie, key: "magpie:cursor", displayName: "Cursor")

    /// 真实输出结构（邮箱已匿名）：4 窗口 + Total 聚合 + readAt 带东八区偏移
    private let realOutput = """
    [
      {
        "provider": "cursor",
        "name": "Cursor",
        "kind": "subscription",
        "plan": "Pro",
        "user": "someone@example.com",
        "windows": [
          {"name": "Cursor Models", "used": 6.108888888888889, "remaining": 93.89, "resetsAt": "2026-11-08T06:11:50Z"},
          {"name": "Other Models", "used": 28.044444444444444, "remaining": 71.95, "resetsAt": "2026-11-08T06:11:50Z"},
          {"name": "Grok Bot", "used": 21.549133, "remaining": 78.45, "resetsAt": "2026-10-14T09:48:44.876Z"},
          {"name": "Total", "used": 7.1534391534391535, "remaining": 92.85, "resetsAt": "2026-11-08T06:11:50Z"}
        ],
        "readAt": "2026-10-13T11:28:22.168077+08:00"
      }
    ]
    """

    private func parse(_ json: String, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SourceResult {
        MagpieSource.parse(data: Data(json.utf8), provider: "cursor", identity: identity, now: now)
    }

    func testSuccessPicksTwoTightestRealWindows() throws {
        let readAt = try XCTUnwrap(isoDate("2026-10-13T11:28:22.168077+08:00"))
        let r = parse(realOutput, now: readAt.addingTimeInterval(60))
        XCTAssertEqual(r.status, .success)
        let snap = try XCTUnwrap(r.snapshot)
        // 主值 = 最紧张的真实窗口（28%），不是 Total 聚合口径（7%）
        XCTAssertEqual(snap.primaryUsedPercent, 28)
        // 双条放紧张度前二：Other Models / Grok Bot；标签经 meta 下发窗口短名
        XCTAssertEqual(snap.fiveHour?.percentage, 28)
        XCTAssertEqual(snap.meta["fiveLabel"], "Other")
        XCTAssertEqual(snap.weekly?.percentage, 22)
        XCTAssertEqual(snap.meta["weeklyLabel"], "Grok")
        XCTAssertEqual(snap.meta["plan"], "Pro")
        // readAt（带时区偏移）作为观测时间；stale 以它计算
        XCTAssertEqual(r.observedAt, readAt)
        XCTAssertFalse(snap.stale)
        // 重置时间：秒级 Z 与毫秒小数 Z 都要能解析
        XCTAssertEqual(snap.fiveHour?.nextResetTime, isoDate("2026-11-08T06:11:50Z")!.timeIntervalSince1970 * 1000)
        XCTAssertEqual(snap.weekly?.nextResetTime, isoDate("2026-10-14T09:48:44.876Z")!.timeIntervalSince1970 * 1000)
    }

    func testStaleWhenReadAtOlderThanADay() throws {
        let readAt = try XCTUnwrap(isoDate("2026-10-13T11:28:22.168077+08:00"))
        let r = parse(realOutput, now: readAt.addingTimeInterval(25 * 3600))
        XCTAssertTrue(try XCTUnwrap(r.snapshot).stale)
    }

    func testProviderFilterSkipsOtherProviders() throws {
        let mixed = """
        [{"provider": "codex", "windows": [{"name": "5h", "used": 50, "resetsAt": "2026-11-08T06:11:50Z"}]},
         {"provider": "cursor", "plan": "Pro", "windows": [{"name": "Other Models", "used": 9, "resetsAt": "2026-11-08T06:11:50Z"}]}]
        """
        let snap = try XCTUnwrap(parse(mixed).snapshot)
        XCTAssertEqual(snap.primaryUsedPercent, 9)
        XCTAssertEqual(snap.weekly, nil)   // 只剩一个真实窗口 → 单条
        XCTAssertEqual(snap.meta["fiveLabel"], "Other")
    }

    func testSingleWindowFallsBackToOneBar() throws {
        let only = """
        [{"provider": "cursor", "windows": [{"name": "Cursor Models", "used": 3.4, "resetsAt": "2026-11-08T06:11:50Z"}]}]
        """
        let snap = try XCTUnwrap(parse(only).snapshot)
        XCTAssertEqual(snap.primaryUsedPercent, 3)
        XCTAssertNotNil(snap.fiveHour)
        XCTAssertNil(snap.weekly)
        XCTAssertNil(snap.meta["weeklyLabel"])
    }

    func testEmptyArrayIsNoDataYet() {
        guard case .noDataYet = parse("[]").status else {
            return XCTFail("expected noDataYet for empty array")
        }
    }

    func testGarbageOutputIsInvalidPayload() {
        guard case .invalidPayload = parse("not json at all").status else {
            return XCTFail("expected invalidPayload for non-JSON output")
        }
    }

    func testStrictMatchRejectsOtherProviderEntry() {
        let onlyCursor = """
        [{"provider": "cursor", "windows": [{"name": "Cursor Models", "used": 3.4, "resetsAt": "2026-11-08T06:11:50Z"}]}]
        """
        // Kimi 兜底复用 parse：严格匹配时 magpie 里没有该账号就报缺，不能拿别的账号顶数
        let strict = MagpieSource.parse(data: Data(onlyCursor.utf8), provider: "kimi-code-cn",
                                        identity: SourceIdentity(source: .kimi, key: "kimi:default", displayName: "Kimi"),
                                        fallbackToFirst: false)
        guard case .noDataYet = strict.status else {
            return XCTFail("expected noDataYet for missing provider in strict mode")
        }
        XCTAssertNil(strict.snapshot)
        // 默认宽松模式维持原行为：回退到第一条
        XCTAssertNotNil(parse(onlyCursor).snapshot)
    }

    func testResolveBinPrefersConfiguredExecutable() {
        let cfg = AppConfiguration(root: ["magpie": ["binPath": "/usr/bin/true"]])
        XCTAssertEqual(MagpieSource.resolveBin(cfg), "/usr/bin/true")
        let missing = AppConfiguration(root: ["magpie": ["binPath": "/no/such/binary/here"]])
        XCTAssertNil(MagpieSource.resolveBin(missing))
    }

    func testProvidersListFallsBackToLegacySingleValue() {
        XCTAssertEqual(MagpieSource.providers(AppConfiguration(root: [:])), ["cursor"])
        XCTAssertEqual(MagpieSource.providers(AppConfiguration(root: ["magpie": ["provider": "grok"]])), ["grok"])
        XCTAssertEqual(MagpieSource.providers(AppConfiguration(root: ["magpie": ["providers": ["cursor", "grok"]]])),
                       ["cursor", "grok"])
        // 旧 provider 单值与新 providers 并存时列表优先
        XCTAssertEqual(MagpieSource.providers(AppConfiguration(root: ["magpie": ["provider": "grok",
                                                                                "providers": ["cursor"]]])),
                       ["cursor"])
    }

    func testIdentitiesOnePerProviderWithDedupNames() {
        let src = MagpieSource()
        let ids = src.identities(configuration: AppConfiguration(root: ["magpie": ["providers": ["cursor", "grok", "zhipu-glm"]]]),
                                 includeSkipped: false)
        XCTAssertEqual(ids.map { $0.key }, ["magpie:cursor", "magpie:grok", "magpie:zhipu-glm"])
        XCTAssertEqual(ids.map { $0.displayName }, ["Cursor", "Grok", "GLM (magpie)"])
    }

    func testGenericWindowShortNames() throws {
        let glm = """
        [{"provider": "zhipu-glm", "plan": "max", "windows": [
          {"name": "5 hours", "used": 55.4, "resetsAt": "2026-10-13T18:00:00Z"},
          {"name": "7 days", "used": 99.0, "resetsAt": "2026-10-19T18:00:00Z"},
          {"name": "MCP · Month", "used": 7.0, "resetsAt": "2026-11-01T00:00:00Z"}]}]
        """
        let snap = try XCTUnwrap(parse(glm).snapshot)
        XCTAssertEqual(snap.primaryUsedPercent, 99)
        XCTAssertEqual(snap.meta["fiveLabel"], "7d")      // 紧张度第一
        XCTAssertEqual(snap.weekly?.percentage, 55)
        XCTAssertEqual(snap.meta["weeklyLabel"], "5h")
        XCTAssertEqual(snap.meta["plan"], "max")
    }
}
