import XCTest
@testable import QuotaDockCore

// MARK: - HTTP/响应 → SourceStatus 分类

final class ErrorClassificationTests: XCTestCase {

    func testConfirmedUnauthorized() {
        XCTAssertEqual(FetchClassifier.status(forHTTP: 401), .unauthorized(confirmed: true))
        XCTAssertEqual(FetchClassifier.status(forHTTP: 403), .unauthorized(confirmed: true))
    }

    /// 限流和服务端故障都是临时状态：保留旧数据、不写 skip
    func testTransientStatuses() {
        XCTAssertEqual(FetchClassifier.status(forHTTP: 429), .rateLimited)
        XCTAssertEqual(FetchClassifier.status(forHTTP: 500), .serverError(status: 500))
        XCTAssertEqual(FetchClassifier.status(forHTTP: 503), .serverError(status: 503))
        XCTAssertEqual(FetchClassifier.status(forHTTP: 404), .serverError(status: 404))
        XCTAssertTrue(FetchClassifier.status(forHTTP: 429).isTransient)
        XCTAssertTrue(FetchClassifier.status(forHTTP: 502).isTransient)
        XCTAssertFalse(FetchClassifier.status(forHTTP: 401).isTransient)
    }

    func testNetworkError() {
        let status = FetchClassifier.status(forNetworkError: URLError(.timedOut))
        XCTAssertTrue(status.isTransient)
        if case .networkError = status {} else { XCTFail("expected networkError") }
    }

    /// 智谱 200 无数据：只有明确的身份验证失败信号才算确认失效
    func testZhipuInvalidPayloadIdentityRejected() {
        XCTAssertEqual(FetchClassifier.zhipuInvalidPayload(Data("{\"code\":1000,\"msg\":\"身份验证失败。\"}".utf8)),
                       .unauthorized(confirmed: true))
        XCTAssertEqual(FetchClassifier.zhipuInvalidPayload(Data("{\"msg\":\"身份验证失败\"}".utf8)),
                       .unauthorized(confirmed: true))
    }

    func testZhipuInvalidPayloadUnrecognized() {
        if case .invalidPayload = FetchClassifier.zhipuInvalidPayload(Data("{\"code\":9,\"msg\":\"busy\"}".utf8)) {} else {
            XCTFail("expected invalidPayload")
        }
        if case .invalidPayload = FetchClassifier.zhipuInvalidPayload(nil) {} else {
            XCTFail("expected invalidPayload for nil data")
        }
    }

    /// 文案包含"发生了什么 + 保留了什么数据"
    func testDisplayHintMentionsKeptData() {
        let at = Date(timeIntervalSince1970: 1_800_000_000) // 固定时间，formatter 只取 HH:mm
        let zh = FetchClassifier.displayHint(for: .networkError("timeout"), lastGoodAt: at, language: "zh")
        XCTAssertTrue(zh.contains("保留"))
        let zhNone = FetchClassifier.displayHint(for: .networkError("timeout"), lastGoodAt: nil, language: "zh")
        XCTAssertFalse(zhNone.contains("保留"))
        let en = FetchClassifier.displayHint(for: .rateLimited, lastGoodAt: at, language: "en")
        XCTAssertTrue(en.contains("showing data"))
    }
}
