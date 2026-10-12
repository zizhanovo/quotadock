import SwiftUI
import QuotaDockCore

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

// MARK: - 单行内联进度条："5h ▓▓▓░░ 23%"

struct MiniBar: View {
    let label: String
    let entry: LimitEntry?
    let showRemaining: Bool

    private var used: Int { min(entry?.percentage ?? 0, 100) }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: 15, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.13))
                    Capsule().fill(usageColor(used))
                        .frame(width: max(2, geo.size.width * CGFloat(used) / 100))
                }
            }
            .frame(height: 5)
            // 剩余/已用只改数字，颜色阈值不变（同一颜色不随模式反转语义）
            Text(entry == nil ? "-" : "\(FreshnessPolicy.percent(forDisplay: used, showRemaining: showRemaining))%")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(entry == nil ? Color.secondary : usageColor(used))
                .frame(width: 28, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(entry == nil ? "-" : "\(used)%")")
    }
}

// MARK: - 一个 key 的分节：名称行 + 两条 MiniBar + 重置行

struct MiniKeySection: View {
    let kq: KeyQuota
    let showRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(usageColor(kq.quota?.maxPercentage ?? 0))
                    .frame(width: 6, height: 6)
                Text(kq.name).font(.system(size: 11, weight: .semibold))
                Text("…\(kq.keyTail)").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                if let q = kq.quota {
                    Text(q.level.uppercased())
                        .font(.system(size: 8, weight: .bold)).tracking(0.5)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .foregroundStyle(.secondary)
                }
            }
            if let q = kq.quota {
                MiniBar(label: "5h", entry: q.fiveHour, showRemaining: showRemaining)
                MiniBar(label: L("周", "wk"), entry: q.weekly, showRemaining: showRemaining)
                Text(L("重置 5h \(shortCountdown(q.fiveHour?.nextResetTime)) · \(L("周", "wk")) \(shortCountdown(q.weekly?.nextResetTime))",
                      "reset 5h \(shortCountdown(q.fiveHour?.nextResetTime)) · wk \(shortCountdown(q.weekly?.nextResetTime))"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else if let err = kq.error {
                Text(err).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 悬停浮现的设置条（覆盖在卡片底部，不改变窗口尺寸）

struct HoverControls: View {
    @ObservedObject var store: Store
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(L("显示", "Show")).font(.system(size: 9)).foregroundStyle(.tertiary)
                ForEach(store.keyQuotas) { kq in
                    Button { store.toggleKey(kq.keyTail) } label: {
                        HStack(spacing: 2) {
                            Image(systemName: store.isSelected(kq) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 9))
                            Text(kq.name).font(.system(size: 10))
                        }
                        .foregroundStyle(store.isSelected(kq) ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(kq.name)
                }
                Spacer()
                Toggle(L("剩余%", "Left%"), isOn: $store.showRemaining)
                    .toggleStyle(.checkbox).controlSize(.mini).font(.system(size: 9))
                    .help(L("数字显示剩余百分比", "Show remaining percentage"))
            }
            HStack {
                Toggle(L("自动切换", "Auto switch"), isOn: $store.autoOnly)
                    .toggleStyle(.checkbox).controlSize(.mini).font(.system(size: 9))
                    .help(L("只显示用量最高的 key", "Show only the busiest key"))
                Spacer()
                Button(L("收起", "Collapse")) { onCollapse() }
                    .buttonStyle(.borderless).font(.system(size: 9)).foregroundStyle(.secondary)
                Button(L("退出", "Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        .shadow(color: Color.black.opacity(0.18), radius: 5, y: 2)
        .padding(4)
    }
}

// MARK: - 常驻迷你仪表盘（所有信息免点击可见）

struct MiniDashboardView: View {
    @ObservedObject var store: Store
    var onCollapse: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(Fmt.dateWeekHM.string(from: ctx.date))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button { store.refreshAll(force: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(L("立即刷新", "Refresh now"))
                .accessibilityLabel(L("立即刷新", "Refresh now"))
            }
            if store.keyQuotas.isEmpty, let err = store.lastError {
                Text(err).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(store.keyQuotas) { kq in
                MiniKeySection(kq: kq, showRemaining: store.showRemaining)
            }
            if !store.extras.isEmpty {
                Divider()
                ForEach(store.extras) { s in
                    if let five = s.fiveBar, let week = s.weekBar {
                        // Claude Code VPS：5h/周双进度条 + 重置倒计时，与智谱分节同款样式
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(s.usedPercent.map { usageColor($0) } ?? Color.gray)
                                    .frame(width: 6, height: 6)
                                Text(s.name).font(.system(size: 10, weight: .semibold))
                                Spacer(minLength: 8)
                                Text(s.value)
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(s.stale ? Color.orange : Color.secondary)
                            }
                            MiniBar(label: "5h", entry: five, showRemaining: store.showRemaining)
                            MiniBar(label: L("周", "wk"), entry: week, showRemaining: store.showRemaining)
                            Text(L("重置 5h \(shortCountdown(five.nextResetTime)) · \(L("周", "wk")) \(shortCountdown(week.nextResetTime))",
                                  "reset 5h \(shortCountdown(five.nextResetTime)) · wk \(shortCountdown(week.nextResetTime))"))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(s.usedPercent.map { usageColor($0) } ?? Color.gray)
                                    .frame(width: 6, height: 6)
                                Text(s.name).font(.system(size: 10, weight: .semibold))
                                Spacer(minLength: 8)
                                Text(s.value)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(s.usedPercent.map { usageColor($0) } ?? Color.secondary)
                            }
                            Text(s.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(s.name) \(s.value) \(s.detail)")
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 232, alignment: .topLeading)
        .frame(minHeight: 172, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
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
