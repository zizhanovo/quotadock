import SwiftUI

// MARK: - 形态切换：仪表盘（默认）↔ 吸边细条

/// 形态切换：仪表盘（默认）↔ 吸边细条（悬停设置里"收起"，点细条回来）
struct PanelRootView: View {
    @ObservedObject var store: Store
    @State private var collapsed: Bool
    var onOpenSettings: (() -> Void)? = nil

    init(store: Store, initiallyCollapsed: Bool = false, onOpenSettings: (() -> Void)? = nil) {
        self.store = store
        _collapsed = State(initialValue: initiallyCollapsed)
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        if collapsed {
            EdgeStrip(store: store, onTap: {
                withAnimation(.easeOut(duration: 0.15)) { collapsed = false; store.stripMode = false }
            })
        } else {
            MiniDashboardView(store: store, onCollapse: {
                withAnimation(.easeOut(duration: 0.15)) {
                    collapsed = true
                    store.stripMode = true
                    let e = nearestDockEdgeFromPanel()
                    store.stripEdge = e
                    UserDefaults.standard.set(e.rawValue, forKey: "stripEdge")
                }
            }, onOpenSettings: onOpenSettings)
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
