import SwiftUI
import QuotaDockCore

// MARK: - 常驻迷你仪表盘（v2 信息层级：摘要 → 服务列表 → 次要操作）

/// 面板顺序固定：总览摘要（最紧张项）→ 服务列表（按紧张度降序）→ 悬停设置（来源/显示/操作）。
/// 所有信息免点击可见；悬停底部浮现设置面板。
struct MiniDashboardView: View {
    @ObservedObject var store: Store
    var onCollapse: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DT.rowSpacing) {
            // 头部：本地时间 + 手动刷新（唯一主动作按钮）
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(Fmt.dateWeekHM.string(from: ctx.date))
                        .font(.system(size: DT.Size.name, weight: .semibold, design: .rounded))
                }
                Spacer()
                if let onOpenSettings {
                    Button { onOpenSettings() } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: DT.Size.value, weight: .medium))
                            .frame(minWidth: DT.minHitSize - 6, minHeight: DT.minHitSize - 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(L("打开设置（连接来源/验证/显示偏好）", "Open settings (sources / verify / preferences)"))
                    .accessibilityLabel(L("打开设置", "Open settings"))
                }
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

            // 2. 服务列表：统一图表行，按紧张度降序（智谱 key 与其他服务同一版式）
            let rows = store.usageRows
            if rows.isEmpty, let err = store.lastError {
                Text(err).font(.system(size: DT.Size.body)).foregroundStyle(.secondary)
            }
            let tightestID = rows.first(where: { $0.primary != nil })?.id
            ForEach(rows) { row in
                UnifiedUsageRow(row: row,
                                showRemaining: store.showRemaining,
                                isTightest: row.id == tightestID)
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
