import XCTest
@testable import QuotaDockCore

// MARK: - 用量历史：采样落盘 / 剪枝 / 协调器联动

final class HistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var clock: TestClock!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qd-hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clock = TestClock()
    }

    func testAppendAndPersistRoundtrip() {
        let url = dir.appendingPathComponent("history.json")
        let h = HistoryStore(url: url, now: { self.clock.date })
        h.append(identityKey: "zp:a#X1", source: .zhipu, displayName: "卡A",
                 point: HistoryPoint(t: clock.date.timeIntervalSince1970, u: 30, f: 25, w: 8))
        clock.advance(180)
        h.append(identityKey: "zp:a#X1", source: .zhipu, displayName: "卡A",
                 point: HistoryPoint(t: clock.date.timeIntervalSince1970, u: 40, f: 35, w: 9))
        // 新实例（重启）从磁盘恢复
        let h2 = HistoryStore(url: url, now: { self.clock.date })
        XCTAssertEqual(h2.points(identityKey: "zp:a#X1").count, 2)
        XCTAssertEqual(h2.readAll()["zp:a#X1"]?.displayName, "卡A")
        XCTAssertEqual(h2.points(identityKey: "zp:a#X1").last?.u, 40)
    }

    /// 超过 7 天保留期的点被剪掉
    func testPruneBeyondRetention() {
        let url = dir.appendingPathComponent("history.json")
        let h = HistoryStore(url: url, now: { self.clock.date })
        h.append(identityKey: "cc:h", source: .claudeCode, displayName: "CC",
                 point: HistoryPoint(t: clock.date.timeIntervalSince1970, u: 10, f: 10, w: 1))
        clock.advance(8 * 86400)   // +8 天
        h.append(identityKey: "cc:h", source: .claudeCode, displayName: "CC",
                 point: HistoryPoint(t: clock.date.timeIntervalSince1970, u: 20, f: 20, w: 2))
        XCTAssertEqual(h.points(identityKey: "cc:h").count, 1, "8 天前的点应被剪掉")
        XCTAssertEqual(h.points(identityKey: "cc:h").first?.u, 20)
    }
}

@MainActor
final class CoordinatorHistoryTests: XCTestCase {
    /// 刷新成功 → 采样一个历史点（大屏趋势的数据面）
    func testSuccessSamplesHistoryPoint() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qd-hist-\(UUID().uuidString)")
        let history = HistoryStore(url: dir.appendingPathComponent("h.json"))
        let ident = SourceIdentity(source: .zhipu, key: "zp:t#AA", displayName: "T", shortLabel: "AA")
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let src = MockSource(id: .zhipu, identities: [ident]) { _ in
            SourceResult(identity: ident,
                         snapshot: QuotaSnapshot(primaryUsedPercent: 44,
                                                 fiveHour: LimitEntry(percentage: 44, nextResetTime: 1),
                                                 weekly: LimitEntry(percentage: 9, nextResetTime: 2)),
                         status: .success,
                         observedAt: observed)
        }
        let c = RefreshCoordinator(sources: [src], configProvider: { AppConfiguration(root: [:]) },
                                   cache: CacheStore(url: dir.appendingPathComponent("c.json")),
                                   history: history,
                                   skipList: SkipListStore(url: dir.appendingPathComponent("s.json"),
                                                           legacyURL: dir.appendingPathComponent("t.txt")),
                                   now: { Date(timeIntervalSince1970: 1_800_000_000) })
        c.refreshAll(force: true)
        let deadline = Date().addingTimeInterval(2)
        while history.points(identityKey: ident.key).isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let pts = history.points(identityKey: ident.key)
        XCTAssertEqual(pts.count, 1)
        XCTAssertEqual(pts.first?.u, 44)
        XCTAssertEqual(pts.first?.f, 44)
        XCTAssertEqual(pts.first?.w, 9)
        XCTAssertEqual(pts.first?.t, 1_800_000_000)
    }
}
