import SwiftUI
import QuotaDockCore

// MARK: - 统一用量行：所有服务同一套图表化版式
//
// 三段式：logo+名称+大号百分比 → 进度条(5h/周/单条) → 统一说明行(重置·更新)。
// 数字不再散落：主值只在右上角大号数字，窗口值只在进度条尾，时间只在说明行。

/// 统一行的数据面（智谱 key 与其他服务都映射成这个）
struct UsageRowData: Identifiable {
    let id: String              // 稳定身份
    let name: String
    let suffix: String          // 尾号/套餐/等级 等次级标识（小字）
    let brand: String?          // logo id
    let primary: Int?           // 主值：大号数字、状态色、排序依据
    let five: LimitEntry?
    let weekly: LimitEntry?
    let singleLabel: String?    // 无窗口服务（MiMo/Codex）的单条进度条标签
    let resetFallback: String   // 无重置窗口时的补充（重置日期 / credits）
    let observedAt: Date?
    let stale: Bool
    let statusHint: String?     // 无数据/错误时的引导文案（替代旧版散落文本）
}

struct UnifiedUsageRow: View {
    let row: UsageRowData
    let showRemaining: Bool
    let isTightest: Bool

    private var used: Int { min(row.primary ?? 0, 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 1. 标识行：logo + 名称 + 次级标识 …… 大号主值
            HStack(spacing: 5) {
                brandMark
                Text(row.name)
                    .font(.system(size: DT.Size.name, weight: isTightest ? .semibold : .medium))
                    .lineLimit(1).truncationMode(.middle)
                if !row.suffix.isEmpty {
                    Text(row.suffix)
                        .font(.system(size: DT.Size.badge)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if row.primary != nil {
                    // 大号主值是全行唯一的醒目数字；颜色按紧张度
                    Text("\(FreshnessPolicy.percent(forDisplay: used, showRemaining: showRemaining))%")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(usageColor(used))
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: DT.Size.value))
                        .foregroundStyle(.tertiary)
                }
            }

            if row.primary != nil {
                // 2. 图表：5h / 周 双条，或单条（MiMo 已用 / Codex 周）
                if let five = row.five {
                    MiniBar(label: "5h", entry: five, showRemaining: showRemaining)
                }
                if let weekly = row.weekly {
                    MiniBar(label: L("周", "wk"), entry: weekly, showRemaining: showRemaining)
                }
                if row.five == nil, row.weekly == nil, let label = row.singleLabel {
                    MiniBar(label: label,
                            entry: LimitEntry(percentage: used),
                            showRemaining: showRemaining)
                }
                // 3. 统一说明行：重置倒计时（或本轮异常提示）· 数据时间
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(row.statusHint ?? resetText)
                        .foregroundStyle(row.statusHint == nil ? Color.secondary : Color.orange)
                    Spacer(minLength: 4)
                    if let at = row.observedAt {
                        freshnessText(at)
                    }
                }
                .font(.system(size: DT.Size.badge))
                .foregroundStyle(row.stale ? Color.orange : Color.secondary)
            } else if let hint = row.statusHint {
                // 无数据：引导文案（发生了什么 + 能做什么）
                Text(hint)
                    .font(.system(size: DT.Size.body)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var brandMark: some View {
        if let id = row.brand, let img = BrandLogo.logoImage(id) {
            Image(nsImage: img).resizable().renderingMode(.template)
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
        } else {
            Circle().fill(usageColor(used)).frame(width: 6, height: 6)
                .frame(width: 12, height: 12)
        }
    }

    private var resetText: String {
        var parts: [String] = []
        if let five = row.five { parts.append("5h " + shortCountdown(five.nextResetTime)) }
        if let weekly = row.weekly { parts.append(L("周", "wk") + " " + shortCountdown(weekly.nextResetTime)) }
        if !parts.isEmpty { return L("重置 ", "reset ") + parts.joined(separator: " · ") }
        return row.resetFallback
    }

    private func freshnessText(_ at: Date) -> some View {
        let age = Date().timeIntervalSince(at)
        let f = age > FreshnessPolicy.staleAfter ? Fmt.shortDateTime : Fmt.bjTime
        let prefix = row.stale ? "⚠ " + L("停更 ", "stale ") : L("更新 ", "up ")
        return Text(prefix + f.string(from: at))
    }

    private var accessibilitySummary: String {
        let value = row.primary.map { "\($0)%" } ?? L("无数据", "no data")
        return "\(row.name) \(value) \(resetText)"
    }
}
