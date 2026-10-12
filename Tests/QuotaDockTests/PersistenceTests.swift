import XCTest
@testable import QuotaDockCore

// MARK: - 缓存与 skip 名单

final class PersistenceTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qd-persist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: CacheStore

    func testCacheRoundtrip() {
        let cache = CacheStore(url: dir.appendingPathComponent("cache.json"))
        let snap = QuotaSnapshot(primaryUsedPercent: 42,
                                 fiveHour: LimitEntry(percentage: 42, nextResetTime: 1_800_000_000_000),
                                 weekly: LimitEntry(percentage: 8),
                                 detail: "detail", stale: false, meta: ["level": "max"])
        cache.write(CachedRecord(source: "zhipu", identityKey: "zp:x#A1", displayName: "卡",
                                 snapshot: snap, observedAt: Date(timeIntervalSince1970: 100),
                                 expiresAt: Date(timeIntervalSince1970: 100 + 86400)))
        let read = cache.read(identityKey: "zp:x#A1")
        XCTAssertEqual(read?.snapshot, snap)
        XCTAssertEqual(read?.displayName, "卡")
        // 新实例（模拟重启）从磁盘恢复
        let reloaded = CacheStore(url: dir.appendingPathComponent("cache.json"))
        XCTAssertNotNil(reloaded.read(identityKey: "zp:x#A1"))
    }

    /// schemaVersion 不匹配的记录整体作废（字段漂移防护）
    func testCacheRejectsForeignSchemaVersion() throws {
        let url = dir.appendingPathComponent("cache.json")
        let foreign = """
        {"zp:x#A1":{"schemaVersion":99,"source":"zhipu","identityKey":"zp:x#A1","displayName":"x",
          "snapshot":{"primaryUsedPercent":1,"fiveHour":null,"weekly":null,"detail":"","stale":false,"meta":{}},
          "observedAt":100,"expiresAt":200}}
        """
        try foreign.write(to: url, atomically: true, encoding: .utf8)
        let cache = CacheStore(url: url)
        XCTAssertNil(cache.read(identityKey: "zp:x#A1"))
    }

    /// 超过 staleAfter 的旧会话记录不恢复首屏
    func testRestoreSkipsStaleRecords() {
        let cache = CacheStore(url: dir.appendingPathComponent("cache.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = SourceIdentity(source: .kimi, key: "kimi:default", displayName: "Kimi")
        cache.write(CachedRecord(source: "kimi", identityKey: fresh.key, displayName: "Kimi",
                                 snapshot: QuotaSnapshot(primaryUsedPercent: 10),
                                 observedAt: now.addingTimeInterval(-3600),
                                 expiresAt: now.addingTimeInterval(82800)))
        cache.write(CachedRecord(source: "zhipu", identityKey: "zp:old#Z9", displayName: "旧卡",
                                 snapshot: QuotaSnapshot(primaryUsedPercent: 10),
                                 observedAt: now.addingTimeInterval(-90000),
                                 expiresAt: now.addingTimeInterval(-3600)))
        let restored = cache.restoreOutcomes(now: now)
        XCTAssertNotNil(restored["kimi:default"])
        XCTAssertNil(restored["zp:old#Z9"])
    }

    // MARK: SkipListStore

    func testSkipAddIsSkippedRemove() {
        let skip = SkipListStore(url: dir.appendingPathComponent("skip.json"),
                                 legacyURL: dir.appendingPathComponent("skip.txt"))
        let ident = SourceIdentity(source: .zhipu, key: "zp:provider:p1#AB12",
                                   displayName: "卡", shortLabel: "AB12")
        XCTAssertFalse(skip.isSkipped(ident))
        skip.add(ident, reason: "HTTP 401")
        XCTAssertTrue(skip.isSkipped(ident))
        XCTAssertEqual(skip.all.count, 1)
        skip.remove(ident)
        XCTAssertFalse(skip.isSkipped(ident))
    }

    /// v1 尾号文件只读迁移：同尾号的智谱身份视为 skip，其他源不受影响
    func testLegacyTailFileMigration() throws {
        let legacy = dir.appendingPathComponent("skip.txt")
        try "C0DE\n  \nAB12\n".write(to: legacy, atomically: true, encoding: .utf8)
        let skip = SkipListStore(url: dir.appendingPathComponent("skip.json"), legacyURL: legacy)
        let zhipu = SourceIdentity(source: .zhipu, key: "zp:provider:pid#AB12",
                                   displayName: "卡", shortLabel: "AB12")
        let other = SourceIdentity(source: .codex, key: "codex:default", displayName: "Codex")
        XCTAssertTrue(skip.isSkipped(zhipu))
        XCTAssertFalse(skip.isSkipped(other))
        // 恢复：remove 同时清掉旧名单里的尾号
        skip.remove(zhipu)
        XCTAssertFalse(skip.isSkipped(zhipu))
    }

    /// v1 的 "individual" 哨兵：整体关闭个人套餐探测
    func testLegacyIndividualSentinelBlocksIndividualIdentity() throws {
        let legacy = dir.appendingPathComponent("skip.txt")
        try "individual\n".write(to: legacy, atomically: true, encoding: .utf8)
        let skip = SkipListStore(url: dir.appendingPathComponent("skip.json"), legacyURL: legacy)
        XCTAssertTrue(skip.legacyTailList.contains("individual"))
        let individual = SourceIdentity(source: .zhipu, key: "zp:individual#XY9Z",
                                        displayName: "个人", shortLabel: "XY9Z")
        XCTAssertFalse(skip.isSkipped(individual), "哨兵本身按 key 匹配，不拦截尾号身份")
        // 拦截发生在 ZhipuSource 枚举层（见 ZhipuSource.resolveEntries 的 legacyTailList 检查）
    }
}
