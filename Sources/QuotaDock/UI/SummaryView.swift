import SwiftUI
import QuotaDockCore

// MARK: - 空态引导卡
// 有数据时不放摘要卡：列表已按紧张度降序、首行加粗，"最紧张"再复述一遍是冗余；
// 只有列表为空时需要引导（缺什么、怎么修）。

struct EmptyStateCard: View {
    var body: some View {
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
