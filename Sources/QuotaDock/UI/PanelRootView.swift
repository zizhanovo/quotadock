import SwiftUI
import QuotaDockCore

// MARK: - 形态切换：吸边条（默认/静止态）↔ 仪表盘（展开态）
//
// 交互模型（v2.1.1）：收纳/展开状态只有 store.stripMode 一份。
// - 默认收纳为吸边条；悬停 0.35s 展开或点击展开
// - 鼠标离开 2.5s 一律自动收纳回原边（例外：设置窗口开着、拖动中）
// - 头部 ⌄ 随时手动收；展开面板锚定吸边条原位，收纳回到最近的边

struct PanelRootView: View {
    @ObservedObject var store: Store
    var onOpenSettings: (() -> Void)? = nil
    var onOpenDashboard: (() -> Void)? = nil

    init(store: Store, onOpenSettings: (() -> Void)? = nil,
         onOpenDashboard: (() -> Void)? = nil) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onOpenDashboard = onOpenDashboard
    }

    var body: some View {
        if store.stripMode {
            EdgeStrip(store: store,
                      onTap: { store.expandFromStrip() },
                      onHoverDwell: {
                          // 刚自动收纳完的原地驻留不秒重开（防抖动）
                          guard !store.userDragging,
                                Date().timeIntervalSince(store.lastAutoCollapseAt ?? .distantPast) > 0.8
                          else { return }
                          store.expandFromStrip()
                      })
        } else {
            MiniDashboardView(store: store,
                              onCollapse: { store.collapseToStrip() },
                              onOpenSettings: onOpenSettings,
                              onOpenDashboard: onOpenDashboard,
                              onHoverChange: { store.noteHover($0) })
        }
    }
}

/// 面板中心点离哪条屏幕边最近 → 收起时吸哪条
func nearestDockEdgeFromPanel() -> DockEdge {
    guard let w = NSApp.windows.first(where: { $0 is NSPanel }) else { return .right }
    let c = NSPoint(x: w.frame.midX, y: w.frame.midY)
    let screen = NSScreen.screens.first(where: { $0.frame.contains(c) }) ?? NSScreen.main
    guard let v = screen?.visibleFrame else { return .right }
    let dists: [(DockEdge, CGFloat)] = [(.top, v.maxY - c.y), (.bottom, c.y - v.minY),
                                         (.left, c.x - v.minX), (.right, v.maxX - c.x)]
    return dists.min(by: { $0.1 < $1.1 })?.0 ?? .right
}
