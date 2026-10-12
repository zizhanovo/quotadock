import XCTest
@testable import QuotaDockCore

// MARK: - 配置写回：深度合并保留未知字段 + 原子写 + 热加载联动

final class ConfigWriterTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qd-writer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 嵌套字典递归合并；未提及的未知字段原样保留
    func testDeepMergePreservesUnknownFields() {
        let base: [String: Any] = [
            "language": "zh",
            "thresholds": ["yellow": 60, "red": 85, "futureField": true],
            "customSection": ["a": 1],
        ]
        let edits: [String: Any] = [
            "language": "en",
            "thresholds": ["yellow": 50],
            "codex": ["enabled": false],
        ]
        let out = ConfigWriter.applying(edits, to: base)
        XCTAssertEqual(out["language"] as? String, "en")
        let th = out["thresholds"] as? [String: Any]
        XCTAssertEqual(th?["yellow"] as? Int, 50, "嵌套字典合并而不是整体替换")
        XCTAssertEqual(th?["red"] as? Int, 85)
        XCTAssertEqual((th?["futureField"] as? Bool), true, "未知字段保留")
        XCTAssertNotNil(out["customSection"], "未提及的 section 保留")
        XCTAssertEqual((out["codex"] as? [String: Any])?["enabled"] as? Bool, false)
    }

    /// 数组整体替换（servers/keys 语义）
    func testArraysAreReplaced() {
        let base: [String: Any] = ["zhipu": ["keys": [["name": "old", "key": "x.y"]]]]
        let edits: [String: Any] = ["zhipu": ["keys": []]]
        let out = ConfigWriter.applying(edits, to: base)
        XCTAssertEqual(((out["zhipu"] as? [String: Any])?["keys"] as? [[String: Any]])?.count, 0)
    }

    /// 写回 → ConfigurationStore 热加载读到新值
    func testWriteThenHotReload() throws {
        let url = dir.appendingPathComponent("config.json")
        try ConfigWriter.write(["language": "zh", "refreshIntervalSeconds": 180], to: url)
        let store = ConfigurationStore(path: url)
        XCTAssertEqual(store.currentSnapshot().refreshInterval, 180)

        let base = ConfigWriter.readRaw(url) ?? [:]
        let merged = ConfigWriter.applying(["refreshIntervalSeconds": 600], to: base)
        try ConfigWriter.write(merged, to: url)
        XCTAssertTrue(store.reloadIfChanged())
        XCTAssertEqual(store.currentSnapshot().refreshInterval, 600)
        XCTAssertEqual(store.currentSnapshot().revision, 1)
    }

    /// pretty JSON 可读（人手改友好）且 roundtrip 无损
    func testWriteIsPrettyAndRoundtrips() throws {
        let url = dir.appendingPathComponent("config.json")
        try ConfigWriter.write(["b": 2, "a": ["x": 1]], to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n  "), "应当是 pretty-printed")
        XCTAssertTrue(text.range(of: "\"a\"")!.lowerBound < text.range(of: "\"b\"")!.lowerBound, "键排序")
        let back = ConfigWriter.readRaw(url)
        XCTAssertEqual(back?["b"] as? Int, 2)
        XCTAssertEqual((back?["a"] as? [String: Any])?["x"] as? Int, 1)
    }
}
