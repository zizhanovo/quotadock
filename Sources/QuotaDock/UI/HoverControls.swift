import SwiftUI
import QuotaDockCore

// MARK: - 悬停设置面板（面板底部浮现：来源状态 → 显示偏好 → 操作）

struct HoverControls: View {
    @ObservedObject var store: Store
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 1. 来源状态：每个数据源一颗状态点（连接健康度一览）
            HStack(spacing: 8) {
                Text(L("来源", "Sources")).font(.system(size: DT.Size.badge)).foregroundStyle(.tertiary)
                ForEach(store.sourceLines) { line in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(line.ok ? Color(red: 0.20, green: 0.75, blue: 0.35) : Color.secondary.opacity(0.55))
                            .frame(width: 5, height: 5)
                        Text("\(line.name) \(line.state)")
                            .font(.system(size: DT.Size.badge))
                            .foregroundStyle(.secondary)
                    }
                    .help("\(line.name): \(line.state)")
                }
                Spacer(minLength: 0)
            }

            // 2. 显示偏好：key 勾选 + 剩余% + 自动切换
            if !store.keyQuotas.isEmpty {
                HStack(spacing: 8) {
                    Text(L("显示", "Show")).font(.system(size: DT.Size.badge)).foregroundStyle(.tertiary)
                    ForEach(store.keyQuotas) { kq in
                        Button { store.toggleKey(kq.keyTail) } label: {
                            HStack(spacing: 2) {
                                Image(systemName: store.isSelected(kq) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: DT.Size.badge))
                                Text(kq.name).font(.system(size: DT.Size.caption))
                            }
                            .foregroundStyle(store.isSelected(kq) ? Color.accentColor : Color.secondary)
                            .padding(.vertical, 1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help(kq.name)
                        .accessibilityLabel(L("显示 \(kq.name)", "show \(kq.name)"))
                    }
                    Spacer()
                }
            }
            HStack(spacing: 10) {
                Toggle(L("剩余%", "Left%"), isOn: $store.showRemaining)
                    .toggleStyle(.checkbox).controlSize(.mini).font(.system(size: DT.Size.badge))
                    .help(L("数字显示剩余百分比（颜色阈值不变）", "Show remaining percentage (color thresholds unchanged)"))
                Toggle(L("自动切换", "Auto switch"), isOn: $store.autoOnly)
                    .toggleStyle(.checkbox).controlSize(.mini).font(.system(size: DT.Size.badge))
                    .help(L("只显示用量最高的 key", "Show only the busiest key"))
                Spacer()
                // 3. 操作
                Button {
                    store.refreshAll(force: true)
                } label: {
                    Label(L("刷新", "Refresh"), systemImage: "arrow.clockwise")
                        .font(.system(size: DT.Size.badge))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(L("强制全部立即刷新（重探失效 key）", "Force refresh all (re-probe skipped keys)"))
                .accessibilityLabel(L("立即刷新", "Refresh now"))
                Button(L("收起", "Collapse")) { onCollapse() }
                    .buttonStyle(.borderless).font(.system(size: DT.Size.badge)).foregroundStyle(.secondary)
                    .accessibilityLabel(L("收起为吸边条", "Collapse to edge strip"))
                Button(L("退出", "Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: DT.Size.badge)).foregroundStyle(.secondary)
                    .accessibilityLabel(L("退出 QuotaDock", "Quit QuotaDock"))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
        .padding(4)
    }
}
