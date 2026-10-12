import Foundation

// MARK: - 版本化快照缓存（最近可信值；禁止写入任何凭据）

/// 一条缓存记录。schemaVersion 变更时整体作废重写，避免字段漂移。
public struct CachedRecord: Codable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let source: String
    public let identityKey: String
    public let displayName: String
    public let snapshot: QuotaSnapshot
    public let observedAt: Date
    public let expiresAt: Date     // 过期后仍可展示但必须标注缓存时间

    public init(source: String, identityKey: String, displayName: String,
                snapshot: QuotaSnapshot, observedAt: Date, expiresAt: Date) {
        self.schemaVersion = Self.schemaVersion
        self.source = source
        self.identityKey = identityKey
        self.displayName = displayName
        self.snapshot = snapshot
        self.observedAt = observedAt
        self.expiresAt = expiresAt
    }
}

/// 单文件 JSON 仓库（~/.cache/quotadock/quota-cache.json）。
/// 用途：进程重启后立即显示上次会话的可信值（标注缓存时间），并在整文件损坏时静默重建。
/// QuotaSnapshot 按构造不含 token/API key/SSH 凭据，缓存面天然无敏感字段。
public final class CacheStore {
    public let url: URL
    private let lock = NSLock()
    private var records: [String: CachedRecord] = [:]
    private static let staleAfter: TimeInterval = 86400

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/quotadock/quota-cache.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONDecoder().decode([String: CachedRecord].self, from: data) else { return }
        // 版本不匹配整体作废
        records = obj.filter { $0.value.schemaVersion == CachedRecord.schemaVersion }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func read(identityKey: String) -> CachedRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[identityKey]
    }

    public func write(_ record: CachedRecord) {
        lock.lock(); defer { lock.unlock() }
        records[record.identityKey] = record
        persist()
    }

    /// 恢复上次会话状态：仅未过期太久（< staleAfter）的记录用于首屏
    public func restoreOutcomes(now: Date = Date()) -> [String: SourceOutcome] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: SourceOutcome] = [:]
        for record in records.values {
            guard now.timeIntervalSince(record.observedAt) < Self.staleAfter else { continue }
            guard let sid = SourceID(rawValue: record.source) else { continue }
            let identity = SourceIdentity(
                source: sid,
                key: record.identityKey,
                displayName: record.displayName,
                shortLabel: record.identityKey.split(separator: "#").last.map(String.init)
            )
            out[record.identityKey] = SourceOutcome(
                identity: identity,
                snapshot: record.snapshot,
                lastGoodAt: record.observedAt,
                status: .noDataYet(hint: ""),
                displayName: record.displayName
            )
        }
        return out
    }
}
