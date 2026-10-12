import SwiftUI
import QuotaDockCore

// MARK: - 形态切换：吸边条（默认/静止态）↔ 仪表盘（展开态）
//
// 交互模型（v2.1）：
// - 默认收纳为吸边条；悬停 0.35s 展开为临时预览（防误触驻留）
// - 鼠标离开面板 2.5s 后自动收纳回原边原位
// - 点击吸边条 / 拖动面板 / 打开设置 = 固定展开（不自动收）；"收起"按钮手动收
// - 展开面板锚定在吸边条原位（不飞回默认角），收纳回到最近的边

struct PanelRootView: View {
    @ObservedObject var store: Store
    @State private var collapsed: Bool
    var onOpenSettings: (() -> Void)? = nil
    @State private var autoCollapseTask: Task<Void, Never>?

    init(store: Store, initiallyCollapsed: Bool = true, onOpenSettings: (() -> Void)? = nil) {
        self.store = store
        _collapsed = State(initialValue: initiallyCollapsed)
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        if collapsed {
            EdgeStrip(store: store,
                      onTap: { expand(pinned: true) },
                      onHoverDwell: {
                          guard !store.userDragging else { return }
                          expand(pinned: false)
                      })
        } else {
            MiniDashboardView(store: store,
                              onCollapse: collapse,
                              onOpenSettings: onOpenSettings,
                              onHoverChange: { hovering in
                                  if hovering {
                                      autoCollapseTask?.cancel()
                                  } else {
                                      scheduleAutoCollapse()
                                  }
                              })
        }
    }

    // MARK: 展开/收纳

    private func expand(pinned: Bool) {
        // 先记录吸边条锚点（窗口此刻还是条的几何），展开后面板贴着它出现
        if let w = NSApp.windows.first(where: { $0 is NSPanel }) {
            store.pendingExpandAnchor = (store.stripEdge,
                                         NSPoint(x: w.frame.midX, y: w.frame.midY))
        }
        withAnimation(.easeOut(duration: 0.15)) {
            store.pinnedOpen = pinned
            collapsed = false
            store.stripMode = false
        }
    }

    private func collapse() {
        withAnimation(.easeOut(duration: 0.15)) {
            collapsed = true
            store.pinnedOpen = false
            store.stripMode = true
            let e = nearestDockEdgeFromPanel()
            store.stripEdge = e
            UserDefaults.standard.set(e.rawValue, forKey: "stripEdge")
        }
    }

    /// 离开面板 2.5s 后自动收纳（固定展开则跳过）；期间重新悬停会取消
    private func scheduleAutoCollapse() {
        autoCollapseTask?.cancel()
        guard !store.pinnedOpen else { return }
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !store.pinnedOpen, !collapsed else { return }
            collapse()
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
