import SwiftUI
import QuotaDockCore

// MARK: - 设置窗口：连接来源 → 验证 → 显示偏好（v2 规格的信息架构）

struct SettingsView: View {
    @ObservedObject var store: Store
    @StateObject private var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    init(store: Store) {
        self.store = store
        _model = StateObject(wrappedValue: SettingsModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sourceSection
                    Divider()
                    verifySection
                    Divider()
                    preferenceSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result = model.saveResult {
                Text(result)
                    .font(.system(size: DT.Size.body))
                    .foregroundStyle(result.hasPrefix(L("写入失败", "write failed")) ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            HStack {
                Button(L("打开配置文件…", "Open config file…")) { model.openConfigFile() }
                Button(L("退出 QuotaDock", "Quit QuotaDock")) { NSApp.terminate(nil) }
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("还原表单", "Revert")) { model.reload() }
                Button(L("保存并生效", "Save & apply")) { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    // MARK: 1. 连接来源

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("连接来源", "Connection sources"),
                         L("凭据路径与开关；改动保存后立即生效", "credential paths & switches; applies on save"))

            sourceCard(L("智谱 Coding Plan", "Zhipu Coding Plan"), id: .zhipu) {
                pathField(L("Provider 配置", "Provider config"), $model.zhipuProviderPath)
                pathField(L("个人套餐凭据", "Personal credentials"), $model.zhipuCredPath)
                manualKeysEditor
            }
            sourceCard("Codex", id: .codex) {
                Toggle(L("启用", "Enabled"), isOn: $model.codexEnabled)
                pathField(L("OAuth 凭据", "OAuth credentials"), $model.codexAuthPath)
                HStack {
                    pathField(L("代理 Host", "Proxy host"), $model.codexProxyHost)
                    TextField(L("端口（空=禁用）", "Port (empty=off)"), text: $model.codexProxyPort)
                        .frame(width: 130)
                }
            }
            sourceCard("Kimi", id: .kimi) {
                Toggle(L("启用", "Enabled"), isOn: $model.kimiEnabled)
                pathField(L("CLI 凭据", "CLI credentials"), $model.kimiCredPath)
            }
            sourceCard("MiMo", id: .mimo) {
                Toggle(L("启用", "Enabled"), isOn: $model.mimoEnabled)
                pathField(L("用量缓存", "Usage cache"), $model.mimoCachePath)
            }
            sourceCard("Claude Code（远程 VPS）", id: .claudeCode) {
                Toggle(L("启用", "Enabled"), isOn: $model.ccEnabled)
                Toggle(L("先在服务器跑 /usage 刷新缓存", "Run /usage on server first"), isOn: $model.ccRefreshUsage)
                Toggle(L("本机 Claude Code（读 ~/.claude.json）", "Local Claude Code (reads ~/.claude.json)"),
                       isOn: $model.ccLocalEnabled)
                HStack {
                    Text(L("SSH 超时(s)", "SSH timeout(s)"))
                    TextField("", text: $model.ccTimeout).frame(width: 50)
                    Spacer()
                }
                ccServersEditor
            }
            sourceCard("Magpie（Cursor / Grok…）", id: .magpie) {
                Toggle(L("启用", "Enabled"), isOn: $model.magpieEnabled)
                pathField(L("magpie 路径（空=自动）", "magpie path (empty=auto)"), $model.magpieBinPath)
                HStack {
                    Text(L("providers（逗号分隔）", "providers (comma separated)"))
                        .frame(width: 140, alignment: .leading)
                        .font(.system(size: DT.Size.body))
                    TextField("cursor, grok, zhipu-glm…", text: $model.magpieProviders)
                }
            }
        }
    }

    /// 一个来源卡片：标题行 = 名称 + 状态点 + 单源"验证"按钮
    private func sourceCard(_ title: String, id: SourceID,
                            @ViewBuilder content: () -> some View) -> some View {
        let line = store.sourceLines.first { $0.id == id.rawValue }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: DT.Size.name, weight: .semibold))
                if let line {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(line.ok ? Color(red: 0.20, green: 0.75, blue: 0.35) : Color.secondary.opacity(0.55))
                            .frame(width: 6, height: 6)
                        Text(line.state).font(.system(size: DT.Size.badge)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(L("验证", "Verify")) {
                    store.refreshSource(id)
                }
                .controlSize(.small)
                .help(L("保存配置后立即抓取该源", "fetch this source now (after saving)"))
            }
            content()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }

    private var manualKeysEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("手工 key（与自动发现合并去重）", "Manual keys (merged with auto-discovery)"))
                .font(.system(size: DT.Size.badge)).foregroundStyle(.tertiary)
            ForEach($model.zhipuManualKeys) { $k in
                HStack {
                    TextField(L("名称", "name"), text: $k.name).frame(width: 110)
                    TextField("key (id.suffix)", text: $k.key)
                    Button(role: .destructive) {
                        model.zhipuManualKeys.removeAll { $0.id == k.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help(L("删除", "remove"))
                }
            }
            Button {
                model.zhipuManualKeys.append(ManualKeyDraft(name: "", key: ""))
            } label: { Label(L("添加 key", "Add key"), systemImage: "plus") }
                .controlSize(.small)
        }
    }

    private var ccServersEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("服务器列表", "Servers"))
                .font(.system(size: DT.Size.badge)).foregroundStyle(.tertiary)
            ForEach($model.ccServers) { $s in
                VStack(spacing: 3) {
                    HStack {
                        TextField(L("SSH 别名/host", "ssh alias/host"), text: $s.host)
                        TextField(L("显示名", "label"), text: $s.name).frame(width: 110)
                        Button(role: .destructive) {
                            model.ccServers.removeAll { $0.id == s.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help(L("删除", "remove"))
                    }
                    HStack {
                        TextField(L("user（空=登录用户）", "user (empty=login)"), text: $s.user).frame(width: 170)
                        TextField(L("SSH 端口（空=22）", "ssh port (empty=22)"), text: $s.sshPort).frame(width: 130)
                        TextField(L("paths 逗号分隔", "paths, comma separated"), text: $s.paths)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03)))
            }
            Button {
                model.ccServers.append(CCServerDraft(host: "", name: "", user: "", sshPort: "", paths: ""))
            } label: { Label(L("添加服务器", "Add server"), systemImage: "plus") }
                .controlSize(.small)
        }
    }

    // MARK: 2. 验证

    private var verifySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("验证", "Verification"), L("配置校验结果与加载状态", "validation results & load state"))
            let issues = store.configFieldIssues + store.configFileIssues
            if issues.isEmpty {
                Label(L("配置有效，无回退字段", "config valid, no field fallbacks"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(issues, id: \.field) { issue in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.field).font(.system(size: DT.Size.body, weight: .semibold))
                        Text("\(issue.reason) · \(issue.hint)")
                            .font(.system(size: DT.Size.body)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 3. 显示偏好

    private var preferenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("显示偏好", "Display preferences"), L("语言/刷新/配色与面板显示", "language/refresh/colors & panel"))
            Picker(L("界面语言", "Language"), selection: $model.language) {
                Text("中文").tag("zh")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented).frame(width: 220)
            Stepper(value: $model.refreshInterval, in: 30...3600, step: 30) {
                Text(L("刷新间隔 \(model.refreshInterval)s", "Refresh every \(model.refreshInterval)s"))
            }.frame(width: 300)
            HStack {
                Stepper(value: $model.yellow, in: 0...99) {
                    Text(L("黄阈值 \(model.yellow)%", "Yellow \(model.yellow)%"))
                }
                Stepper(value: $model.red, in: 1...100) {
                    Text(L("红阈值 \(model.red)%", "Red \(model.red)%"))
                }
            }
            Divider()
            Toggle(L("数字显示剩余百分比（颜色阈值不变）", "Show remaining percentage (color thresholds unchanged)"),
                   isOn: $store.showRemaining)
            Toggle(L("自动只显示最紧张的 key", "Auto-show only the busiest key"), isOn: $store.autoOnly)
            if !store.keyQuotas.isEmpty {
                HStack(spacing: 10) {
                    Text(L("吸边条显示：", "Strip shows:")).font(.system(size: DT.Size.body))
                    ForEach(store.keyQuotas) { kq in
                        Button { store.toggleKey(kq.keyTail) } label: {
                            Image(systemName: store.isSelected(kq) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(store.isSelected(kq) ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless).help(kq.name)
                    }
                }
            }
        }
    }

    // MARK: 小件

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: DT.Size.name, weight: .bold))
            Text(subtitle).font(.system(size: DT.Size.body)).foregroundStyle(.secondary)
        }
    }

    private func pathField(_ label: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading)
                .font(.system(size: DT.Size.body))
            TextField("~/.zcode/…", text: value)
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSString(string: value.wrappedValue).expandingTildeInPath))
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help(L("在 Finder 中显示", "Reveal in Finder"))
        }
    }
}
