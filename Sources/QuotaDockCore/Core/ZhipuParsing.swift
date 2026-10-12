import Foundation

// MARK: - 智谱 quota 响应解析（纯函数，fixture 可测）

public enum ZhipuParser {

    /// 解析 /api/monitor/usage/quota/limit 响应。
    /// unit==3 → 5小时窗口，unit==6 → 周；兜底：重置时间离现在更近(<6h)的是 5h 窗口。
    public static func parse(_ body: Data, now: Date = Date()) -> QuotaData? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]] else { return nil }
        let level = data["level"] as? String ?? "-"

        func entry(_ d: [String: Any]) -> LimitEntry {
            LimitEntry(
                percentage: (d["percentage"] as? NSNumber)?.intValue ?? 0,
                usage: (d["usage"] as? NSNumber)?.intValue,
                currentValue: (d["currentValue"] as? NSNumber)?.intValue,
                nextResetTime: (d["nextResetTime"] as? NSNumber)?.doubleValue
            )
        }

        var tokenEntries: [(Int, LimitEntry)] = []   // (unit, entry)
        var tools: LimitEntry?
        for d in limits {
            let type = d["type"] as? String ?? ""
            if type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT" {
                tokenEntries.append(((d["unit"] as? NSNumber)?.intValue ?? 0, entry(d)))
            } else if type == "TIME_LIMIT" {
                tools = entry(d)
            }
        }
        var fiveHour = tokenEntries.first { $0.0 == 3 }?.1
        var weekly = tokenEntries.first { $0.0 == 6 }?.1
        if fiveHour == nil || weekly == nil, tokenEntries.count >= 2 {
            let nowMs = now.timeIntervalSince1970 * 1000
            let sorted = tokenEntries.sorted { ($0.1.nextResetTime ?? 0) < ($1.1.nextResetTime ?? 0) }
            if fiveHour == nil, let e = sorted.first, (e.1.nextResetTime ?? 0) - nowMs < 6 * 3600 * 1000 {
                fiveHour = e.1
            }
            if weekly == nil {
                let candidates = sorted.filter { $0.1.nextResetTime != fiveHour?.nextResetTime }
                weekly = candidates.last?.1 ?? sorted.last?.1
            }
        }
        if fiveHour == nil, weekly == nil, let only = tokenEntries.first {
            weekly = only.1 // 只有一条时按周额度展示
        }
        return QuotaData(fiveHour: fiveHour, weekly: weekly, tools: tools, level: level)
    }
}
