import Foundation

// MARK: - 失效身份名单：只存"确认失效"的稳定身份 + 旧版尾号迁移

/// v2 skip 名单。与 v1 的尾号文件（quotadock-skip.txt）双轨兼容：
/// - 读写以稳定身份 key 为主键（重命名/重复尾号/换 provider 不串）
/// - 旧尾号文件只读迁移：命中同尾号的智谱身份视为 skip（保持 v1 行为）
/// - 手动强制刷新会重探 skip 身份；成功即自动移出名单（恢复路径）
public final class SkipListStore {
    public struct Entry: Codable, Equatable {
        public let identity: String     // 稳定身份 key，如 "zp:provider:bigmodel-api-2#J7Fk"
        public let reason: String
        public let since: Date
    }

    public static let shared = SkipListStore()

    public let url: URL                 // v2 名单
    public let legacyURL: URL           // v1 尾号文件（只读）

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var legacyTails: Set<String> = []

    public init(url: URL? = nil, legacyURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.url = url ?? home.appendingPathComponent(".config/quotadock/skip-v2.json")
        self.legacyURL = legacyURL ?? home.appendingPathComponent(".config/quotadock-skip.txt")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = obj
        }
        if let s = try? String(contentsOf: legacyURL, encoding: .utf8) {
            legacyTails = Set(s.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 身份是否被跳过（稳定身份命中，或智谱身份尾号命中旧名单）
    public func isSkipped(_ identity: SourceIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if entries.contains(where: { $0.identity == identity.key }) { return true }
        if identity.source == .zhipu, let tail = identity.shortLabel, legacyTails.contains(tail) {
            return true
        }
        return false
    }

    /// 记录一个确认失效的身份（仅 unauthorized(confirmed) 调用）
    public func add(_ identity: SourceIdentity, reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard !entries.contains(where: { $0.identity == identity.key }) else { return }
        entries.append(Entry(identity: identity.key, reason: reason, since: Date()))
        persist()
    }

    /// 恢复监测：身份重新有效时移出（强制刷新重探成功路径）
    public func remove(_ identity: SourceIdentity) {
        lock.lock(); defer { lock.unlock() }
        let before = entries.count
        entries.removeAll { $0.identity == identity.key }
        if identity.source == .zhipu, let tail = identity.shortLabel {
            legacyTails.remove(tail)
        }
        if entries.count != before { persist() }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = []
        legacyTails = []
        persist()
    }

    public var all: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public var legacyTailList: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(legacyTails)
    }
}
