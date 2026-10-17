import XCTest
@testable import QuotaDockCore

// MARK: - KimiSource 测试：usages 解析 + magpie 兜底合并

final class KimiSourceTests: XCTestCase {
    private let identity = SourceIdentity(source: .kimi, key: "kimi:default", displayName: "Kimi")

    private func native(_ status: SourceStatus) -> SourceResult {
        SourceResult(identity: identity, snapshot: nil, status: status)
    }

    private func magpieSuccess(percent: Int) -> SourceResult {
        let snap = QuotaSnapshot(primaryUsedPercent: percent,
                                 fiveHour: LimitEntry(percentage: percent),
                                 weekly: nil, detail: "", stale: false,
                                 meta: ["fiveLabel": "5h"])
        return SourceResult(identity: identity, snapshot: snap, status: .success)
    }

    // 原生 usages 解析

    func testParseUsages() throws {
        let body = """
        {"usages": {"limit_5h": {"used_ratio": 0.284, "reset_time": "2026-10-14T18:00:00Z"},
                    "limit_7d": {"used_ratio": 0.071, "reset_time": "2026-10-19T18:00:00Z"}}}
        """
        let r = KimiSource.parse(body: Data(body.utf8), identity: identity, tokenFresh: true)
        XCTAssertEqual(r.status, .success)
        let snap = try XCTUnwrap(r.snapshot)
        XCTAssertEqual(snap.primaryUsedPercent, 28)   // 主值 = 最紧张窗口
        XCTAssertEqual(snap.fiveHour?.percentage, 28)
        XCTAssertEqual(snap.weekly?.percentage, 7)
        XCTAssertEqual(snap.fiveHour?.nextResetTime, isoDate("2026-10-14T18:00:00Z")!.timeIntervalSince1970 * 1000)
    }

    func testParseUnparseableWithStaleTokenIsCredentialStale() {
        let r = KimiSource.parse(body: Data("{}".utf8), identity: identity, tokenFresh: false)
        guard case .credentialStale = r.status else {
            return XCTFail("expected credentialStale for stale token + bad payload")
        }
    }

    // 兜底合并

    func testMergedPrefersMagpieData() {
        let out = KimiSource.merged(native: native(.credentialStale(hint: "token 过期")),
                                    fallback: magpieSuccess(percent: 41), identity: identity)
        XCTAssertEqual(out.status, .success)
        XCTAssertEqual(out.snapshot?.primaryUsedPercent, 41)
    }

    func testMergedAppendsMagpieHintWhenBothHaveNoAccount() {
        let out = KimiSource.merged(native: native(.noDataYet(hint: "缺少 ~/.kimi-code 凭据")),
                                    fallback: native(.noDataYet(hint: "magpie 里还没有 kimi-code-cn 账号")),
                                    identity: identity)
        guard case .noDataYet(let hint) = out.status else {
            return XCTFail("expected noDataYet when neither side has an account")
        }
        XCTAssertTrue(hint.contains("缺少 ~/.kimi-code"))
        XCTAssertTrue(hint.contains("magpie"))
    }

    func testMergedAppendsMagpieHintOnStaleToken() {
        let out = KimiSource.merged(native: native(.credentialStale(hint: "token 过期 · 跑一次 kimi CLI 自动续期")),
                                    fallback: native(.noDataYet(hint: "magpie 里还没有 kimi-code-cn 账号")),
                                    identity: identity)
        guard case .credentialStale(let hint) = out.status else {
            return XCTFail("expected credentialStale to survive the merge")
        }
        XCTAssertTrue(hint.contains("token 过期"))
        XCTAssertTrue(hint.contains("magpie"))
    }

    func testMergedKeepsNativeWhenMagpieFailedToRun() {
        let nativeResult = native(.credentialStale(hint: "token 过期"))
        let out = KimiSource.merged(native: nativeResult,
                                    fallback: native(.networkError("magpie 查询超时")),
                                    identity: identity)
        XCTAssertEqual(out.status, nativeResult.status)   // 兜底失败不掩盖原生报错
        XCTAssertNil(out.snapshot)
    }
}
