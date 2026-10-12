import SwiftUI
import QuotaDockCore

// MARK: - 悬停快捷条（面板底部浮现）
// 完整设置在齿轮按钮的设置窗口里；这里只留高频快捷项：key 勾选 + 两个开关 + 三个动作。
// 窄面板约束：文案一律不折行（fixedSize），超出时靠省略号，绝不竖排。

struct HoverControls: View {
    @ObservedObject var store: Store
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !store.keyQuotas.isEmpty {
                HStack(spacing: 8) {
                    Text(L("显示", "Show"))
                        .font(.system(size: DT.Size.badge)).foregroundStyle(.tertiary)
                        .fixedSize()
                    ForEach(store.keyQuotas) { kq in
                        Button { store.toggleKey(kq.keyTail) } label: {
                            HStack(spacing: 2) {
                                Image(systemName: store.isSelected(kq) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: DT.Size.badge))
                                Text(kq.name).font(.system(size: DT.Size.caption)).lineLimit(1)
                            }
                            .foregroundStyle(store.isSelected(kq) ? Color.accentColor : Color.secondary)
                            .fixedSize()
                            .padding(.vertical, 1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help(kq.name)
                        .accessibilityLabel(L("显示 \(kq.name)", "show \(kq.name)"))
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 10) {
                Toggle(L("剩余%", "Left%"), isOn: $store.showRemaining)
                    .toggleStyle(.checkbox).controlSize(.mini).font(.system(size: DT.Size.badge))
                    .fixedSize()
                    .help(L("数字显示剩余百分比（颜色阈值不变）", "Show remaining percentage (color thresholds unchanged)"))
                Toggle(L("自动切换", "Auto switch"), isOn: $store.autoOnly)
                    .toggleStyle(.checkbox).controlSize(.mini).font(.system(size: DT.Size.badge))
                    .fixedSize()
                    .help(L("只显示用量最高的 key", "Show only the busiest key"))
                Spacer(minLength: 6)
                Button {
                    store.refreshAll(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: DT.Size.caption, weight: .semibold))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(L("强制全部立即刷新（重探失效 key）", "Force refresh all (re-probe skipped keys)"))
                .accessibilityLabel(L("立即刷新", "Refresh now"))
                Button(L("收起", "Collapse")) { onCollapse() }
                    .buttonStyle(.borderless)
                    .font(.system(size: DT.Size.badge)).foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel(L("收起为吸边条", "Collapse to edge strip"))
                Button(L("退出", "Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: DT.Size.badge)).foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel(L("退出 QuotaDock", "Quit QuotaDock"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
        .padding(.horizontal, 4).padding(.bottom, 4)
    }
}
