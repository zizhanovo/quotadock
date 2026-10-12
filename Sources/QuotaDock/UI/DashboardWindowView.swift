import SwiftUI
import Combine
import QuotaDockCore

// MARK: - 大屏仪表盘窗口：环形仪表 + 7 天趋势 + 重置时间轴
//
// 与 Peek 面板分工：Peek 回答"现在紧不紧张"，这里回答"过去一周怎么烧的、
// 下一个重置断崖在哪"。趋势数据来自 HistoryStore（每次刷新成功采样，保留 7 天）。

/// 大屏窗口的视图模型：联动 Store 的刷新结果，定时从磁盘重载历史
@MainActor
final class DashboardWindowModel: ObservableObject {
    @Published var series: [String: HistorySeries] = [:]
    @Published var outcomes: [String: SourceOutcome] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let history: HistoryStore

    init(store: Store) {
        self.history = store.historyStore
        outcomes = store.coordinator.outcomes
        reloadHistory()
        // 每轮刷新后重载历史（文件小，直接整读）
        store.coordinator.$outcomes
            .receive(on: RunLoop.main)
            .sink { [weak self] o in
                self?.outcomes = o
                self?.reloadHistory()
            }
            .store(in: &cancellables)
    }

    func reloadHistory() {
        series = history.readAll()
    }

    /// 最紧张的身份（主值最大）
    var tightest: SourceOutcome? {
        outcomes.values
            .filter { $0.snapshot?.primaryUsedPercent != nil }
            .max { ($0.snapshot?.primaryUsedPercent ?? -1) < ($1.snapshot?.primaryUsedPercent ?? -1) }
    }
}

struct DashboardWindowView: View {
    @StateObject private var model: DashboardWindowModel
    @ObservedObject private var store: Store

    init(store: Store) {
        self.store = store
        _model = StateObject(wrappedValue: DashboardWindowModel(store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                gaugeSection
                trendSection
                timelineSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 700, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 1. 环形仪表：最紧张项的大结论

    private var gaugeSection: some View {
        HStack(alignment: .center, spacing: 28) {
            if let t = model.tightest, let used = t.snapshot?.primaryUsedPercent {
                ZStack {
                    Circle()
                        .trim(from: 0, to: 1)
                        .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Circle()
                        .trim(from: 0, to: CGFloat(min(used, 100)) / 100)
                        .stroke(usageColor(used), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: used)
                    VStack(spacing: 2) {
                        Text("\(FreshnessPolicy.percent(forDisplay: used, showRemaining: store.showRemaining))%")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(usageColor(used))
                        Text(L("已用", "used"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.displayName)
                        .font(.system(size: 17, weight: .semibold))
                    Text(L("当前最紧张 · 更新 ", "tightest now · updated ") + (t.lastGoodAt.map { Fmt.bjTime.string(from: $0) } ?? "-"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    // 服务概览：全部身份的主值一览
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.outcomes.values
                            .sorted { ($0.snapshot?.primaryUsedPercent ?? -1) > ($1.snapshot?.primaryUsedPercent ?? -1) }, id: \.identity.key) { o in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(o.snapshot?.primaryUsedPercent.map { usageColor($0) } ?? Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(o.displayName).font(.system(size: 12))
                                Spacer(minLength: 8)
                                Text((o.snapshot?.primaryUsedPercent).map { "\($0)%" } ?? "—")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(o.snapshot?.primaryUsedPercent.map { usageColor($0) } ?? Color.secondary)
                            }
                            .frame(maxWidth: 220)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: 2. 趋势：7 天多序列折线（主值）

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("用量趋势 · 最近 7 天", "Usage trend · last 7 days"))
                .font(.system(size: 13, weight: .semibold))
            let colored = coloredSeries()
            if colored.count < 2, colored.first?.series.points.count ?? 0 < 2 {
                Text(L("数据积累中：每次刷新记一个点，跑一两天趋势就成型了。", "Collecting data: one point per refresh; trends form in a day or two."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
            } else {
                TrendChart(seriesList: colored)
                    .frame(height: 150)
                // 图例
                HStack(spacing: 12) {
                    ForEach(colored) { c in
                        HStack(spacing: 4) {
                            Circle().fill(c.color).frame(width: 6, height: 6)
                            Text(c.series.displayName).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    struct ColoredSeries: Identifiable {
        let id: String
        let series: HistorySeries
        let color: Color
    }

    private func coloredSeries() -> [ColoredSeries] {
        model.series
            .filter { $0.value.points.count >= 1 }
            .map { ColoredSeries(id: $0.key, series: $0.value, color: Self.color(for: $0.value)) }
            .sorted { $0.id < $1.id }
    }

    /// 折线配色按数据源固定（不随紧张度变色——趋势图要认"这是谁"，不是"现在多紧张"）
    static func color(forSource source: String) -> Color {
        switch source {
        case "zhipu": return Color(red: 0.36, green: 0.45, blue: 0.95)   // 靛蓝
        case "codex": return Color(red: 0.10, green: 0.65, blue: 0.60)   // 青
        case "kimi": return Color(red: 0.55, green: 0.35, blue: 0.85)    // 紫
        case "mimo": return Color(red: 0.90, green: 0.55, blue: 0.15)    // 橙
        case "claudeCode": return Color(red: 0.75, green: 0.35, blue: 0.30) // 赭红
        default: return .secondary
        }
    }

    private static func color(for s: HistorySeries) -> Color {
        color(forSource: s.source)
    }

    // MARK: 3. 重置时间轴：now → 7d，每身份一条轨道

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("重置时间轴 · 从现在起 7 天", "Reset timeline · next 7 days"))
                .font(.system(size: 13, weight: .semibold))
            let nowMs = Date().timeIntervalSince1970 * 1000
            let span: Double = 7 * 86400 * 1000
            let rows = model.outcomes.values
                .filter { $0.snapshot?.fiveHour?.nextResetTime != nil || $0.snapshot?.weekly?.nextResetTime != nil }
                .sorted { $0.displayName < $1.displayName }
            if rows.isEmpty {
                Text(L("暂无带重置窗口的服务", "no services with reset windows"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.identity.key) { o in
                        ResetTrack(name: o.displayName,
                                   color: Self.color(forSource: o.identity.source.rawValue),
                                   fiveAt: o.snapshot?.fiveHour?.nextResetTime,
                                   weeklyAt: o.snapshot?.weekly?.nextResetTime,
                                   nowMs: nowMs, spanMs: span)
                    }
                    // 时间刻度
                    HStack {
                        Text(L("现在", "now"))
                        Spacer()
                        Text("+3.5" + L("天", "d"))
                        Spacer()
                        Text("+7" + L("天", "d"))
                    }
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.leading, 120)
                }
            }
        }
    }
}

// MARK: 折线图（纯 SwiftUI Path）

struct TrendChart: View {
    let seriesList: [DashboardWindowView.ColoredSeries]
    private static let window: TimeInterval = 7 * 86400

    var body: some View {
        GeometryReader { geo in
            let now = Date().timeIntervalSince1970
            let start = now - Self.window
            ZStack(alignment: .leading) {
                // 横向网格：0/50/100%
                ForEach([0, 50, 100], id: \.self) { pct in
                    Path { p in
                        let y = geo.size.height * CGFloat(100 - pct) / 100
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }
                ForEach(seriesList) { c in
                    Path { p in
                        let pts = c.series.points
                            .filter { $0.u != nil && $0.t >= start }
                            .sorted { $0.t < $1.t }
                        guard pts.count > 1 else { return }
                        for (i, point) in pts.enumerated() {
                            let x = geo.size.width * CGFloat((point.t - start) / Self.window)
                            let y = geo.size.height * CGFloat(100 - min(max(point.u ?? 0, 0), 100)) / 100
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(c.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityLabel(L("近 7 天各服务用量百分比折线", "7-day usage percentage lines"))
    }
}

// MARK: 重置轨道：一条服务一行，5h=实心点，周=空心环

struct ResetTrack: View {
    let name: String
    let color: Color
    let fiveAt: Double?
    let weeklyAt: Double?
    let nowMs: Double
    let spanMs: Double

    var body: some View {
        GeometryReader { geo in
            let trackY = geo.size.height / 2
            ZStack(alignment: .leading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: trackY))
                    p.addLine(to: CGPoint(x: geo.size.width, y: trackY))
                }
                .stroke(Color.primary.opacity(0.08), lineWidth: 2)
                if let at = fiveAt, at > nowMs {
                    Circle().fill(color)
                        .frame(width: 8, height: 8)
                        .position(x: x(at, in: geo.size.width), y: trackY)
                        .help(L("5h 窗口重置 \(countdownString(at) ?? "")", "5h window resets \(countdownString(at) ?? "")"))
                }
                if let at = weeklyAt, at > nowMs {
                    Circle().strokeBorder(color, lineWidth: 2)
                        .frame(width: 9, height: 9)
                        .position(x: x(at, in: geo.size.width), y: trackY)
                        .help(L("周窗口重置 \(countdownString(at) ?? "")", "weekly window resets \(countdownString(at) ?? "")"))
                }
            }
        }
        .frame(height: 16)
        .overlay(alignment: .leading) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor).padding(.trailing, 6))
        }
    }

    private func x(_ atMs: Double, in width: CGFloat) -> CGFloat {
        let frac = min(max((atMs - nowMs) / spanMs, 0), 1)
        return 120 + (width - 120) * frac
    }
}
