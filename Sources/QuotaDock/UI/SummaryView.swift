import SwiftUI
import QuotaDockCore

// MARK: - 总览摘要：只回答一个问题——"现在最需要关注什么"

/// 摘要数据（Store 计算后注入，视图无业务逻辑）
struct SummaryInfo {
    let name: String
    let usedPercent: Int?
    let nearestResetMs: Double?    // 最近的未来重置时间（epoch 毫秒）
    let observedAt: Date?
}

/// 有数据：最紧张服务 + 使用百分比 + 颜色状态 + 最近重置窗口 + 数据时间。
/// 无数据：变成引导卡（缺什么、怎么修）。
struct SummaryCard: View {
    let summary: SummaryInfo?
    let showRemaining: Bool
    let lastUpdate: Date?

    var body: some View {
        if let s = summary, let used = s.usedPercent {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(usageColor(used)).frame(width: 7, height: 7)
                    Text(L("最紧张", "Tightest"))
                        .font(.system(size: DT.Size.caption)).foregroundStyle(.secondary)
                    Text(s.name)
                        .font(.system(size: DT.Size.summaryName, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    // 只有最紧张项使用最强的颜色与权重
                    Text("\(FreshnessPolicy.percent(forDisplay: used, showRemaining: showRemaining))%")
                        .font(.system(size: DT.Size.summaryNumber, weight: .bold, design: .rounded))
                        .foregroundStyle(usageColor(used))
                }
                HStack(spacing: 4) {
                    if let reset = s.nearestResetMs {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                        Text(L("重置 \(shortCountdown(reset))", "resets \(shortCountdown(reset))"))
                    }
                    Spacer(minLength: 4)
                    if let at = s.observedAt ?? lastUpdate {
                        Text(L("更新 \(Fmt.bjTime.string(from: at))", "updated \(Fmt.bjTime.string(from: at))"))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: DT.Size.caption))
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L("最紧张 \(s.name) 已用 \(used)%", "tightest \(s.name) \(used)% used"))
        } else {
            // 引导卡：告诉用户缺什么、下一步做什么
            VStack(alignment: .leading, spacing: 3) {
                Text(L("还没有可用数据", "No data yet"))
                    .font(.system(size: DT.Size.summaryName, weight: .semibold))
                Text(L("配置 ~/.config/quotadock/config.json 后点右上角刷新；智谱 key 从 ZCode 自动发现，Codex/Kimi 读本地 CLI 凭据。",
                      "Set up ~/.config/quotadock/config.json then hit refresh; zhipu keys auto-discovered from ZCode, Codex/Kimi read local CLI credentials."))
                    .font(.system(size: DT.Size.body)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
