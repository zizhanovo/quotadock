import SwiftUI
import QuotaDockCore

// MARK: - Design Tokens：面板唯一的视觉常量来源
// 字号下限上移到可读范围（旧版 8pt 徽标/9pt 正文 → 9.5/10.5 起步）；
// 只让"最紧张项"使用更强的颜色和权重，其余行保持次级灰阶。

enum DT {
    // 布局
    static let panelWidth: CGFloat = 256
    static let padding: CGFloat = 12
    static let radius: CGFloat = 12
    static let rowSpacing: CGFloat = 8
    static let barHeight: CGFloat = 5
    static let minHitSize: CGFloat = 22   // 最小点击区域

    // 字号（下限 9.5）
    enum Size {
        static let summaryNumber: CGFloat = 16    // 摘要大号百分比（最紧张项独占）
        static let summaryName: CGFloat = 12
        static let name: CGFloat = 12             // 行名称
        static let value: CGFloat = 11            // 主数值/时间
        static let body: CGFloat = 10.5           // 第二行说明
        static let caption: CGFloat = 10          // 重置行/辅助
        static let badge: CGFloat = 9.5           // 等级徽标
    }
}

// MARK: - 用量配色（阈值可配：thresholds.yellow / thresholds.red）
// 状态颜色永远配合文字/图标，不只依赖颜色本身

func usageColor(_ used: Int) -> Color {
    let th = ConfigurationStore.shared.currentSnapshot().thresholds
    if used < th.yellow { return Color(red: 0.20, green: 0.75, blue: 0.35) }
    if used < th.red { return Color(red: 0.95, green: 0.62, blue: 0.08) }
    return Color(red: 0.92, green: 0.26, blue: 0.22)
}

func usageNSColor(_ used: Int) -> NSColor {
    let th = ConfigurationStore.shared.currentSnapshot().thresholds
    if used < th.yellow { return NSColor(red: 0.20, green: 0.75, blue: 0.35, alpha: 1) }
    if used < th.red { return NSColor(red: 0.95, green: 0.62, blue: 0.08, alpha: 1) }
    return NSColor(red: 0.92, green: 0.26, blue: 0.22, alpha: 1)
}

// MARK: - 单行内联进度条："5h ▓▓▓░░"（精确值不落在条尾：大号主值已是最大窗口，
// 条尾再标一遍只会翻倍数字密度；窗口精确值看条长与颜色，读数走无障碍标签）

struct MiniBar: View {
    let label: String
    let entry: LimitEntry?

    private var used: Int { min(entry?.percentage ?? 0, 100) }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: DT.Size.caption)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.13))
                    Capsule().fill(usageColor(used))
                        .frame(width: max(2, geo.size.width * CGFloat(used) / 100))
                }
            }
            .frame(height: DT.barHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(entry == nil ? "-" : "\(used)%")")
    }
}
