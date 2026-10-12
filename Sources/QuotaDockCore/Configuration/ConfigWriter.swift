import Foundation

// MARK: - 配置写回：编辑结果深度合并进原始 dict（保留未知字段），原子落盘

public enum ConfigWriter {

    /// 深度合并：edits 覆盖 base；两侧都是字典时递归合并，数组与标量整体替换。
    /// 未知字段（未来版本/用户手写的键）原样保留。
    public static func applying(_ edits: [String: Any], to base: [String: Any]) -> [String: Any] {
        merge(base, edits)
    }

    private static func merge(_ base: [String: Any], _ edits: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in edits {
            if let baseDict = out[key] as? [String: Any], let editDict = value as? [String: Any] {
                out[key] = merge(baseDict, editDict)
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// pretty + 排序键的原子写；目录不存在则创建
    public static func write(_ dict: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dict,
                                              options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// 读取文件原始 dict（保留未知字段用）；文件缺失/损坏返回 nil
    public static func readRaw(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
