import SwiftUI
import QuotaDockCore

// MARK: - 服务行：智谱 key 行 + 其他服务行（统一 tokens，按紧张度着色）

/// 一个智谱 key 的分节：名称行 + 两条 MiniBar + 重置行
struct KeyRow: View {
    let kq: KeyQuota
    let showRemaining: Bool
    let isTightest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(usageColor(kq.quota?.maxPercentage ?? 0))
                    .frame(width: 6, height: 6)
                Text(kq.name)
                    .font(.system(size: DT.Size.name, weight: isTightest ? .semibold : .medium))
                Text("…\(kq.keyTail)")
                    .font(.system(size: DT.Size.badge)).foregroundStyle(.secondary)
                Spacer()
                if let q = kq.quota, q.level != "-" {
                    Text(q.level.uppercased())
                        .font(.system(size: DT.Size.badge, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(.tertiary)
                }
            }
            if let q = kq.quota {
                MiniBar(label: "5h", entry: q.fiveHour, showRemaining: showRemaining)
                MiniBar(label: L("周", "wk"), entry: q.weekly, showRemaining: showRemaining)
                Text(L("重置 5h \(shortCountdown(q.fiveHour?.nextResetTime)) · \(L("周", "wk")) \(shortCountdown(q.weekly?.nextResetTime))",
                      "reset 5h \(shortCountdown(q.fiveHour?.nextResetTime)) · wk \(shortCountdown(q.weekly?.nextResetTime))"))
                    .font(.system(size: DT.Size.caption)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else if let err = kq.error {
                // 错误文案："发生了什么 + 现在能做什么"（FetchClassifier 生成）
                Text(err).font(.system(size: DT.Size.body)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 其他服务行：有 5h/周数据走双进度条（Claude Code），否则数值+说明
struct ServiceRow: View {
    let s: ExtraService
    let showRemaining: Bool

    var body: some View {
        if let five = s.fiveBar, let week = s.weekBar {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(s.usedPercent.map { usageColor($0) } ?? Color.gray)
                        .frame(width: 6, height: 6)
                    Text(s.name).font(.system(size: DT.Size.name, weight: .medium))
                    Spacer(minLength: 8)
                    Text(s.value)
                        .font(.system(size: DT.Size.value, design: .rounded))
                        .foregroundStyle(s.stale ? Color.orange : Color.secondary)
                }
                MiniBar(label: "5h", entry: five, showRemaining: showRemaining)
                MiniBar(label: L("周", "wk"), entry: week, showRemaining: showRemaining)
                Text(L("重置 5h \(shortCountdown(five.nextResetTime)) · \(L("周", "wk")) \(shortCountdown(week.nextResetTime))",
                      "reset 5h \(shortCountdown(five.nextResetTime)) · wk \(shortCountdown(week.nextResetTime))"))
                    .font(.system(size: DT.Size.caption)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(s.usedPercent.map { usageColor($0) } ?? Color.gray)
                        .frame(width: 6, height: 6)
                    Text(s.name).font(.system(size: DT.Size.name, weight: .medium))
                    Spacer(minLength: 8)
                    Text(s.value)
                        .font(.system(size: DT.Size.value, weight: .semibold, design: .rounded))
                        .foregroundStyle(s.usedPercent.map { usageColor($0) } ?? Color.secondary)
                }
                Text(s.detail).font(.system(size: DT.Size.body)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(s.name) \(s.value) \(s.detail)")
        }
    }
}
