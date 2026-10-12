import SwiftUI
import QuotaDockCore

// MARK: - 常驻迷你仪表盘（v2 信息层级：摘要 → 服务列表 → 次要操作）

/// 面板顺序固定：总览摘要（最紧张项）→ 服务列表（按紧张度降序）→ 悬停设置（来源/显示/操作）。
/// 所有信息免点击可见；悬停底部浮现设置面板。
struct MiniDashboardView: View {
    @ObservedObject var store: Store
    var onCollapse: (() -> Void)? = nil
    @State private var hovering = false

    /// 摘要指向的行加更强的权重（只有最紧张项）
    private var tightestName: String? {
        store.summary.flatMap { $0.usedPercent != nil ? $0.name : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DT.rowSpacing) {
            // 头部：本地时间 + 手动刷新（唯一主动作按钮）
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(Fmt.dateWeekHM.string(from: ctx.date))
                        .font(.system(size: DT.Size.name, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button { store.refreshAll(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: DT.Size.value, weight: .semibold))
                        .frame(minWidth: DT.minHitSize, minHeight: DT.minHitSize - 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("立即刷新", "Refresh now"))
                .accessibilityLabel(L("立即刷新", "Refresh now"))
            }

            // 1. 总览摘要：最紧张服务 / 引导卡
            SummaryCard(summary: store.summary,
                        showRemaining: store.showRemaining,
                        lastUpdate: store.lastUpdate)

            // 2. 服务列表：智谱 key 行（按紧张度降序）+ 其他服务行
            let keys = store.visibleKeys
            if keys.isEmpty, store.extras.isEmpty, let err = store.lastError {
                Text(err).font(.system(size: DT.Size.body)).foregroundStyle(.secondary)
            }
            ForEach(keys) { kq in
                KeyRow(kq: kq, showRemaining: store.showRemaining,
                       isTightest: kq.name == tightestName)
            }
            if !store.extras.isEmpty {
                Divider()
                ForEach(store.extras) { s in
                    ServiceRow(s: s, showRemaining: store.showRemaining)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DT.padding)
        .frame(width: DT.panelWidth, alignment: .topLeading)
        .frame(minHeight: 172, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DT.radius).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: DT.radius).stroke(Color.primary.opacity(0.1)))
        .overlay(alignment: .bottom) {
            if hovering {
                HoverControls(store: store, onCollapse: { hovering = false; onCollapse?() })
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .windowDrag()
    }
}
