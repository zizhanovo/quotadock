import XCTest
@testable import QuotaDockCore

// MARK: - 智谱 quota 解析 fixtures

final class ZhipuParsingTests: XCTestCase {

    /// 正常：unit=3 五小时窗 + unit=6 周窗 + TIME_LIMIT 工具次数 + level
    func testParseNormal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        {"data":{"level":"max","limits":[
          {"type":"TOKENS_LIMIT","unit":3,"percentage":42,"usage":100,"currentValue":42,"nextResetTime":1800000000000},
          {"type":"TOKENS_LIMIT","unit":6,"percentage":7,"usage":null,"currentValue":7,"nextResetTime":1800400000000},
          {"type":"TIME_LIMIT","unit":1,"percentage":1,"usage":4000,"currentValue":9,"nextResetTime":1802600000000}
        ]}}
        """
        let q = ZhipuParser.parse(Data(json.utf8), now: now)
        XCTAssertNotNil(q)
        XCTAssertEqual(q?.level, "max")
        XCTAssertEqual(q?.fiveHour?.percentage, 42)
        XCTAssertEqual(q?.weekly?.percentage, 7)
        XCTAssertEqual(q?.tools?.usage, 4000)
        XCTAssertEqual(q?.tools?.currentValue, 9)
        XCTAssertEqual(q?.maxPercentage, 42)
    }

    /// 缺 unit：兜底用重置时间离 now 更近（<6h）的一条当 5h 窗
    func testParseUnitFallbackByResetTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = (now.timeIntervalSince1970 + 2 * 3600) * 1000      // 2h 后 → 5h 窗
        let later = (now.timeIntervalSince1970 + 4 * 86400) * 1000    // 4 天后 → 周窗
        let json = """
        {"data":{"level":"Lite","limits":[
          {"type":"TOKENS_LIMIT","percentage":55,"nextResetTime":\(later)},
          {"type":"TOKENS_LIMIT","percentage":12,"nextResetTime":\(soon)}
        ]}}
        """
        let q = ZhipuParser.parse(Data(json.utf8), now: now)
        XCTAssertEqual(q?.fiveHour?.percentage, 12)
        XCTAssertEqual(q?.weekly?.percentage, 55)
    }

    /// 只有一条：按周额度展示
    func testParseSingleEntryAsWeekly() {
        let json = """
        {"data":{"level":"max","limits":[
          {"type":"TOKENS_LIMIT","unit":6,"percentage":31,"nextResetTime":1800400000000}
        ]}}
        """
        let q = ZhipuParser.parse(Data(json.utf8))
        XCTAssertNil(q?.fiveHour)
        XCTAssertEqual(q?.weekly?.percentage, 31)
    }

    /// 缺字段：percentage 缺省 0，usage/currentValue 容 nil
    func testParseMissingFields() {
        let json = """
        {"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3}]}}
        """
        let q = ZhipuParser.parse(Data(json.utf8))
        XCTAssertEqual(q?.fiveHour?.percentage, 0)
        XCTAssertNil(q?.fiveHour?.usage)
        XCTAssertEqual(q?.level, "-")
    }

    func testParseInvalidPayloadReturnsNil() {
        XCTAssertNil(ZhipuParser.parse(Data("{\"code\":1000,\"msg\":\"身份验证失败。\"}".utf8)))
        XCTAssertNil(ZhipuParser.parse(Data("not json".utf8)))
        XCTAssertNil(ZhipuParser.parse(Data("{}".utf8)))
    }

    /// CREDIT_LIMIT 类型同样计入 token 窗口（月卡以 credit 形式下发）
    func testParseCreditLimit() {
        let json = """
        {"data":{"level":"max","limits":[
          {"type":"CREDIT_LIMIT","unit":6,"percentage":88,"nextResetTime":1800400000000}
        ]}}
        """
        let q = ZhipuParser.parse(Data(json.utf8))
        XCTAssertEqual(q?.weekly?.percentage, 88)
        XCTAssertEqual(q?.maxPercentage, 88)
    }
}
