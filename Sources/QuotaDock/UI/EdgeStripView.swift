import SwiftUI
import QuotaDockCore

// MARK: - 吸边条（收起态）：顶/底吸附=横条，左/右吸附=竖条

/// 全部项按紧张度降序，每项「彩色大号百分比 + 品牌logo/首字块」；悬停 tooltip 列名称明细；
/// 点击恢复仪表盘，按住拖到别的边松手换边换方向。
struct EdgeStrip: View {
    @ObservedObject var store: Store
    let onTap: () -> Void

    struct StripItem: Identifiable {
        let id: String
        let name: String
        let used: Int?
        let logo: String?
        let badge: Int?
    }

    /// 名称 → 品牌图标 id（logos/ 目录下的同名 .svg/.png）；nil=无品牌图走首字块
    static func logoID(for name: String) -> String? {
        if name.hasPrefix("Codex") { return "openai" }
        if name.hasPrefix("CC ") { return "claude" }
        if name.hasPrefix("Kimi") { return "kimi" }
        if name.hasPrefix("MiMo") { return "xiaomi" }
        if name.hasPrefix("个人") || name.hasPrefix("Personal") { return "zhipu" }
        return nil
    }

    private var items: [StripItem] {
        var raw: [(String, String, Int?, String?)] = []   // id, name, used, logo
        for k in store.visibleKeys {
            raw.append((k.identityKey, k.name, k.quota.map { min(max($0.maxPercentage, 0), 100) }, "zhipu"))
        }
        for s in store.extras {
            if let u = s.usedPercent { raw.append((s.id, s.name, min(u, 100), EdgeStrip.logoID(for: s.name))) }
        }
        var counts: [String: Int] = [:]
        for r in raw where r.3 != nil { counts[r.3!, default: 0] += 1 }
        var idx: [String: Int] = [:]
        return raw.map {
            guard let lid = $0.3 else { return StripItem(id: $0.0, name: $0.1, used: $0.2, logo: nil, badge: nil) }
            idx[lid, default: 0] += 1
            // 同 logo 多个实例（如两台 CC）才显示 ①② 角标
            let badge = (counts[lid] ?? 0) > 1 ? idx[lid] : nil
            return StripItem(id: $0.0, name: $0.1, used: $0.2, logo: lid, badge: badge)
        }
    }

    /// logo 目录：优先 QUOTADOCK_LOGOS 环境变量（离屏渲染用），否则 app bundle Resources/logos
    static func logosDir() -> URL? {
        if let p = ProcessInfo.processInfo.environment["QUOTADOCK_LOGOS"] { return URL(fileURLWithPath: p) }
        return Bundle.main.resourceURL?.appendingPathComponent("logos")
    }
    private static var logoCache: [String: NSImage?] = [:]
    private static func logoImage(_ id: String) -> NSImage? {
        if let c = logoCache[id] { return c }
        var img: NSImage?
        for ext in ["svg", "png"] {
            if let u = EdgeStrip.logosDir()?.appendingPathComponent("\(id).\(ext)") {
                img = NSImage(contentsOf: u)
                if img != nil { break }
            }
        }
        img?.isTemplate = true   // 单色模板渲染，深浅模式统一 secondary 灰
        logoCache[id] = img
        return img
    }

    /// 识别块：品牌 logo（文件缺失/加载失败回退首字块）；智谱多卡同 logo 靠 ①② 角标区分
    @ViewBuilder
    private func ident(_ it: StripItem) -> some View {
        if let lid = it.logo, let img = EdgeStrip.logoImage(lid) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: img).resizable().renderingMode(.template)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                if let b = it.badge {
                    Text("\(b)")
                        .font(.system(size: 5, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(1.5)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: 3, y: 3)
                }
            }
            .frame(height: 13)
        } else {
            Text(String(it.name.prefix(1)))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 12)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.09)))
        }
    }

    /// 单项块：彩色大号百分比（或状态图标）+ logo/首字块。
    /// 没有数值的服务展示名称与状态图标，不用 ❌ 作为唯一信息。
    @ViewBuilder
    private func block(_ it: StripItem) -> some View {
        VStack(spacing: 2) {
            if let u = it.used {
                Text("\(FreshnessPolicy.percent(forDisplay: u, showRemaining: store.showRemaining))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(usageColor(u))
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ident(it)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(it.name) \(it.used.map { "\($0)%" } ?? L("无数据", "no data"))")
    }

    var body: some View {
        let horizontal = (store.stripEdge == .top || store.stripEdge == .bottom)
        // 全部可见项合并后按紧张度统一降序（key 行 + 服务行不再各自为序）
        let list = items.sorted { ($0.used ?? -1) > ($1.used ?? -1) }
        let tip = list.map { it in it.name + (it.used.map { " \($0)%" } ?? " " + L("无数据", "no data")) }.joined(separator: " · ")
            + L(" · 点击展开仪表盘 · 拖到别的边可换吸", " · click to expand · drag to another edge")
        Group {
            if horizontal {
                HStack(spacing: 8) { ForEach(list) { block($0) } }
            } else {
                VStack(spacing: 6) { ForEach(list) { block($0) } }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 8)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .windowDrag()
        .help(tip)
        .accessibilityLabel(L("QuotaDock 吸边条", "QuotaDock edge strip"))
        .accessibilityHint(tip)
    }
}
