import XCTest
@testable import QuotaDockCore

// MARK: - 测试用具

/// 可手动推进的时钟
final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ s: TimeInterval) { date = date.addingTimeInterval(s) }
}

/// 线程安全盒子
final class LockedBox<T> {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); defer { lock.unlock() }; v = newValue }
    }
}

/// 一次性门闩：先 release 后 wait 也成立
final class Gate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SourceResult, Never>?
    private var result: SourceResult?

    func wait() async -> SourceResult {
        await withCheckedContinuation { cont in
            lock.lock(); defer { lock.unlock() }
            if let result { cont.resume(returning: result) } else { continuation = cont }
        }
    }

    func release(_ result: SourceResult) {
        lock.lock(); defer { lock.unlock() }
        if let cont = continuation { continuation = nil; cont.resume(returning: result) }
        else { self.result = result }
    }
}

/// 可编程的假数据源
final class MockSource: QuotaSource {
    let id: SourceID
    var identitiesList: [SourceIdentity]
    var dynamicIdentities: ((AppConfiguration) -> [SourceIdentity])?
    var handler: (SourceIdentity) async -> SourceResult
    var skipList: SkipListStore?      // 模拟 ZhipuSource 的 skip 过滤契约
    private let counter = LockedBox(0)
    private let flagsLock = NSLock()
    private var _includeSkippedFlags: [Bool] = []

    var fetchCount: Int { counter.value }
    var includeSkippedFlags: [Bool] {
        flagsLock.lock(); defer { flagsLock.unlock() }
        return _includeSkippedFlags
    }

    init(id: SourceID, identities: [SourceIdentity],
         handler: @escaping (SourceIdentity) async -> SourceResult) {
        self.id = id
        self.identitiesList = identities
        self.handler = handler
    }

    func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity] {
        flagsLock.lock(); defer { flagsLock.unlock() }
        _includeSkippedFlags.append(includeSkipped)
        if let dynamicIdentities { return dynamicIdentities(configuration) }
        guard let skipList else { return identitiesList }
        return identitiesList.filter { includeSkipped || !skipList.isSkipped($0) }
    }

    func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult {
        counter.mutate { $0 += 1 }
        return await handler(configuration.identity)
    }
}

extension LockedBox {
    func mutate(_ f: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        f(&v)
    }
}

// MARK: - RefreshCoordinator：合并表 / 代次 / 单飞 / 节流 / skip

@MainActor
final class RefreshCoordinatorTests: XCTestCase {
    private var clock: TestClock!
    private var cache: CacheStore!
    private var skipList: SkipListStore!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cache = CacheStore(url: dir.appendingPathComponent("cache.json"))
        skipList = SkipListStore(url: dir.appendingPathComponent("skip.json"),
                                 legacyURL: dir.appendingPathComponent("skip.txt"))
        clock = TestClock()
    }

    private func makeCoordinator(_ src: QuotaSource, root: [String: Any] = [:]) -> RefreshCoordinator {
        RefreshCoordinator(sources: [src], configProvider: { AppConfiguration(root: root) },
                           cache: cache, skipList: skipList, now: { self.clock.date })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           timeout: TimeInterval = 2, _ msg: String = "") async {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timeout: \(msg)")
    }

    private let ident = SourceIdentity(source: .zhipu, key: "zp:test#AB12", displayName: "测试卡", shortLabel: "AB12")
    private func snapshot(_ pct: Int) -> QuotaSnapshot {
        QuotaSnapshot(primaryUsedPercent: pct, detail: "p\(pct)")
    }

    // MARK: 合并表

    func testSuccessAppliesSnapshotAndWritesCache() async {
        let src = MockSource(id: .zhipu, identities: [ident]) { _ in
            SourceResult(identity: self.ident, snapshot: self.snapshot(30), status: .success)
        }
        let c = makeCoordinator(src)
        c.refreshAll(force: true)
        await waitUntil({ c.outcomes[self.ident.key]?.snapshot != nil }, "snapshot applied")
        XCTAssertEqual(c.outcomes[ident.key]?.status, .success)
        XCTAssertNotNil(c.outcomes[ident.key]?.lastGoodAt)
        let record = cache.read(identityKey: ident.key)
        XCTAssertEqual(record?.snapshot.primaryUsedPercent, 30)
        XCTAssertEqual(record?.identityKey, ident.key)
    }

    /// 临时故障：保留最近成功值与 lastGoodAt，只换状态
    func testTransientFailureKeepsLastGoodValue() async {
        let failing = LockedBox(false)
        let src = MockSource(id: .zhipu, identities: [ident]) { _ in
            if failing.value {
                return SourceResult(identity: self.ident, snapshot: nil, status: .serverError(status: 503))
            }
            return SourceResult(identity: self.ident, snapshot: self.snapshot(66), status: .success)
        }
        let c = makeCoordinator(src)
        c.refreshAll(force: true)
        await waitUntil({ c.outcomes[self.ident.key]?.snapshot?.primaryUsedPercent == 66 }, "first success")
        let goodAt = c.outcomes[ident.key]?.lastGoodAt

        failing.value = true
        clock.advance(400)
        c.refreshAll()
        await waitUntil({ c.outcomes[self.ident.key]?.status == .serverError(status: 503) }, "failure status")
        XCTAssertEqual(c.outcomes[ident.key]?.snapshot?.primaryUsedPercent, 66, "旧值必须保留")
        XCTAssertEqual(c.outcomes[ident.key]?.lastGoodAt, goodAt)
        XCTAssertTrue(skipList.all.isEmpty, "临时故障绝不写 skip")
    }

    /// 429 同样保留旧值、不写 skip（v1 的致命 bug 场景）
    func testRateLimitedKeepsValueAndSkipsNothing() async {
        let failing = LockedBox(false)
        let src = MockSource(id: .zhipu, identities: [ident]) { _ in
            if failing.value {
                return SourceResult(identity: self.ident, snapshot: nil, status: .rateLimited)
            }
            return SourceResult(identity: self.ident, snapshot: self.snapshot(10), status: .success)
        }
        let c = makeCoordinator(src)
        c.refreshAll(force: true)
        await waitUntil({ c.outcomes[self.ident.key]?.snapshot?.primaryUsedPercent == 10 }, "seeded")
        failing.value = true
        clock.advance(400)
        c.refreshAll()
        await waitUntil({ c.outcomes[self.ident.key]?.status == .rateLimited }, "429 status")
        XCTAssertEqual(c.outcomes[ident.key]?.snapshot?.primaryUsedPercent, 10)
        XCTAssertTrue(skipList.all.isEmpty)
    }

    func testConfirmedUnauthorizedClearsValueAndWritesSkip() async {
        let src = MockSource(id: .zhipu, identities: [ident]) { _ in
            SourceResult(identity: self.ident, snapshot: nil, status: .unauthorized(confirmed: true))
        }
        let c = makeCoordinator(src)
        c.refreshAll(force: true)
        await waitUntil({ !skipList.all.isEmpty }, "skip written")
        XCTAssertNil(c.outcomes[ident.key]?.snapshot)
        XCTAssertNil(c.outcomes[ident.key]?.lastGoodAt)
        XCTAssertTrue(skipList.isSkipped(ident))
    }

    // MARK: 单飞 / 节流 / 代次

    /// 同一身份在飞时，普通轮次不得再发一个请求
    func testSingleFlightPerIdentity() async {
        let src = MockSource(id: .zhipu, identities: [ident]) { _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            return SourceResult(identity: self.ident, snapshot: self.snapshot(1), status: .success)
        }
        let c = makeCoordinator(src)
        c.refreshAll()   // 开始任务
        clock.advance(400)
        c.refreshAll()   // 到期，但在飞 → 单飞跳过
        await waitUntil({ c.outcomes[self.ident.key] != nil }, "completed")
        XCTAssertEqual(src.fetchCount, 1)
    }

    /// 未到期轮次直接跳过；到期后重新抓取
    func testThrottleHonorsInterval() async {
        let src = MockSource(id: .zhipu, identities: [ident]) { _ in
            SourceResult(identity: self.ident, snapshot: self.snapshot(1), status: .success)
        }
        let c = makeCoordinator(src)
        c.refreshAll()
        await waitUntil({ src.fetchCount == 1 }, "first")
        clock.advance(10)   // < 180s
        c.refreshAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(src.fetchCount, 1, "间隔内不得重复抓取")
        clock.advance(200)
        c.refreshAll()
        await waitUntil({ src.fetchCount == 2 }, "due again")
    }

    /// 手动强制刷新：取消在飞旧任务并 bump 代次；旧代次的迟到结果不得覆盖新代次
    func testForceRefreshDiscardsStaleGenerationResult() async {
        let gateA = Gate()
        let gateB = Gate()
        let which = LockedBox(0)
        let src = MockSource(id: .zhipu, identities: [ident]) { _ in
            if which.value == 0 { return await gateA.wait() }
            return await gateB.wait()
        }
        let c = makeCoordinator(src)
        c.refreshAll(force: true)      // 代次 1，任务 A 在飞
        which.value = 1
        c.refreshAll(force: true)      // 代次 2：A 被取消，任务 B 在飞
        // A 的迟到结果（值 999）在旧代次上完成 → 必须被丢弃
        gateA.release(SourceResult(identity: ident, snapshot: snapshot(999), status: .success))
        gateB.release(SourceResult(identity: ident, snapshot: snapshot(5), status: .success))
        await waitUntil({ c.outcomes[self.ident.key]?.snapshot != nil }, "applied")
        XCTAssertEqual(c.outcomes[ident.key]?.snapshot?.primaryUsedPercent, 5,
                       "旧代次的 999 不得覆盖新代次的 5")
    }

    /// 停用的数据源：结果表里的旧行必须清掉
    func testDisabledSourcePrunesOutcomes() async {
        let codexID = SourceIdentity(source: .codex, key: "codex:default", displayName: "Codex")
        let src = MockSource(id: .codex, identities: [codexID]) { _ in
            SourceResult(identity: codexID, snapshot: QuotaSnapshot(primaryUsedPercent: 20), status: .success)
        }
        let root = LockedBox<[String: Any]>(["codex": ["enabled": true]])
        let c = RefreshCoordinator(sources: [src], configProvider: { AppConfiguration(root: root.value) },
                                   cache: cache, skipList: skipList, now: { self.clock.date })
        c.refreshAll(force: true)
        await waitUntil({ c.outcomes[codexID.key] != nil }, "seeded")
        root.value = ["codex": ["enabled": false]]
        clock.advance(400)
        c.refreshAll()
        await waitUntil({ c.outcomes[codexID.key] == nil }, "pruned")
    }

    /// 身份消失（配置删掉 key/服务器）→ 行不残留
    func testVanishedIdentityPruned() async {
        let listed = LockedBox(true)
        let src = MockSource(id: .zhipu, identities: []) { _ in
            SourceResult(identity: self.ident, snapshot: self.snapshot(1), status: .success)
        }
        src.dynamicIdentities = { _ in listed.value ? [self.ident] : [] }
        let c = makeCoordinator(src)
        c.refreshAll(force: true)
        await waitUntil({ c.outcomes[self.ident.key] != nil }, "seeded")
        listed.value = false
        clock.advance(400)
        c.refreshAll()
        await waitUntil({ c.outcomes[self.ident.key] == nil }, "pruned")
    }

    // MARK: skip 重探

    /// 手动强制刷新重探 skip 身份；成功自动移出名单（恢复路径）
    func testForceRefreshReprobesSkippedIdentityAndRecovers() async {
        let src = MockSource(id: .zhipu, identities: [ident]) { _ in
            SourceResult(identity: self.ident, snapshot: self.snapshot(3), status: .success)
        }
        src.skipList = skipList
        skipList.add(ident, reason: "test")
        let c = makeCoordinator(src)
        c.refreshAll()   // includeSkipped=false → 不抓
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(src.fetchCount, 0)
        XCTAssertFalse(src.includeSkippedFlags.contains(true))

        c.refreshAll(force: true)   // includeSkipped=true → 重探
        await waitUntil({ !skipList.isSkipped(self.ident) }, "auto-removed from skip")
        XCTAssertEqual(c.outcomes[ident.key]?.snapshot?.primaryUsedPercent, 3)
    }

    /// 重启恢复：seedFromCache 立即可显示上次会话的最近可信值
    func testSeedFromCacheRestoresLastSession() async {
        cache.write(CachedRecord(source: "zhipu", identityKey: ident.key, displayName: "测试卡",
                                 snapshot: snapshot(77),
                                 observedAt: clock.date.addingTimeInterval(-60),
                                 expiresAt: clock.date.addingTimeInterval(86340)))
        let c = RefreshCoordinator(sources: [], configProvider: { AppConfiguration(root: [:]) },
                                   cache: cache, skipList: skipList, now: { self.clock.date })
        c.seedFromCache()
        XCTAssertEqual(c.outcomes[ident.key]?.snapshot?.primaryUsedPercent, 77)
    }
}
