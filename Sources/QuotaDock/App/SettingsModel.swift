import Foundation
import Combine
import AppKit
import QuotaDockCore

// MARK: - 设置窗口的编辑模型：连接来源 → 验证 → 显示偏好

/// 手工 key / CC 服务器的可编辑草稿行
struct ManualKeyDraft: Identifiable {
    var id = UUID()
    var name: String
    var key: String
}

struct CCServerDraft: Identifiable {
    var id = UUID()
    var host: String
    var name: String
    var user: String
    var sshPort: String
    var paths: String     // 逗号分隔
}

/// 设置页编辑状态。保存 = 构造 edits dict → 深度合并进文件原始 dict（保留未知字段）
/// → 原子写回 → 立即热加载。显示偏好（剩余%/自动切换/勾选）走 Store 的 UserDefaults，不进 config。
@MainActor
final class SettingsModel: ObservableObject {
    // 智谱
    @Published var zhipuProviderPath: String
    @Published var zhipuCredPath: String
    @Published var zhipuManualKeys: [ManualKeyDraft]
    // Codex
    @Published var codexEnabled: Bool
    @Published var codexAuthPath: String
    @Published var codexProxyHost: String
    @Published var codexProxyPort: String   // "" = 禁用代理路
    // Kimi
    @Published var kimiEnabled: Bool
    @Published var kimiCredPath: String
    // MiMo
    @Published var mimoEnabled: Bool
    @Published var mimoCachePath: String
    // Claude Code
    @Published var ccEnabled: Bool
    @Published var ccRefreshUsage: Bool
    @Published var ccTimeout: String
    @Published var ccServers: [CCServerDraft]
    // 全局
    @Published var language: String          // "zh" | "en"
    @Published var refreshInterval: Int
    @Published var yellow: Int
    @Published var red: Int

    /// 保存后回显：配置层校验结果（字段/原因/修复提示）
    @Published var saveResult: String?

    private let config: ConfigurationStore

    init(config: ConfigurationStore = .shared) {
        self.config = config
        let c = config.currentSnapshot()
        zhipuProviderPath = c["zhipu"]?.str("providerConfigPath", "~/.zcode/v2/provider_config.json")
            ?? "~/.zcode/v2/provider_config.json"
        zhipuCredPath = c["zhipu"]?.str("credentialsPath", "~/.zcode/v2/credentials.json")
            ?? "~/.zcode/v2/credentials.json"
        zhipuManualKeys = (c["zhipu"]?.list("keys") ?? []).map {
            ManualKeyDraft(name: $0.str("name", ""), key: $0.str("key", ""))
        }
        codexEnabled = c["codex"]?.bool("enabled", true) ?? true
        codexAuthPath = c["codex"]?.str("authPath", "~/.codex/auth.json") ?? "~/.codex/auth.json"
        codexProxyHost = c["codex"]?.str("proxyHost", "127.0.0.1") ?? "127.0.0.1"
        let port = c["codex"]?.int("proxyPort", 6152) ?? 6152
        codexProxyPort = port == 0 ? "" : String(port)
        kimiEnabled = c["kimi"]?.bool("enabled", true) ?? true
        kimiCredPath = c["kimi"]?.str("credentialsPath", "~/.kimi-code/credentials/kimi-code.json")
            ?? "~/.kimi-code/credentials/kimi-code.json"
        mimoEnabled = c["mimo"]?.bool("enabled", true) ?? true
        mimoCachePath = c["mimo"]?.str("cachePath", "~/.cache/quotadock/mimo-usage.json")
            ?? "~/.cache/quotadock/mimo-usage.json"
        ccEnabled = c["claudeCode"]?.bool("enabled", true) ?? true
        ccRefreshUsage = c["claudeCode"]?.bool("refreshUsage", true) ?? true
        ccTimeout = String(c["claudeCode"]?.int("sshConnectTimeout", 10) ?? 10)
        ccServers = (c["claudeCode"]?.list("servers") ?? []).map {
            CCServerDraft(host: $0.str("host"),
                          name: $0.str("name", ""),
                          user: $0.str("user", ""),
                          sshPort: $0.str("sshPort", ""),
                          paths: $0.strList("paths").joined(separator: ", "))
        }
        language = c.language == "en" ? "en" : "zh"
        refreshInterval = Int(c.refreshInterval)
        let th = c.thresholds
        yellow = th.yellow
        red = th.red
    }

    /// 编辑 → config.json（保留未知字段），然后立即热加载并回显校验结果
    func save() {
        var edits: [String: Any] = [
            "language": language,
            "refreshIntervalSeconds": refreshInterval,
            "thresholds": ["yellow": yellow, "red": red],
            "zhipu": [
                "providerConfigPath": zhipuProviderPath,
                "credentialsPath": zhipuCredPath,
                "keys": zhipuManualKeys
                    .filter { $0.key.count > 8 }
                    .map { ["name": $0.name, "key": $0.key] },
            ] as [String: Any],
            "codex": [
                "enabled": codexEnabled,
                "authPath": codexAuthPath,
                "proxyHost": codexProxyHost,
                "proxyPort": Int(codexProxyPort) ?? 0,
            ] as [String: Any],
            "kimi": ["enabled": kimiEnabled, "credentialsPath": kimiCredPath],
            "mimo": ["enabled": mimoEnabled, "cachePath": mimoCachePath],
            "claudeCode": [
                "enabled": ccEnabled,
                "refreshUsage": ccRefreshUsage,
                "sshConnectTimeout": Int(ccTimeout) ?? 10,
                "servers": ccServers
                    .filter { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { s in
                        ["host": s.host.trimmingCharacters(in: .whitespaces),
                         "name": s.name,
                         "user": s.user,
                         "sshPort": s.sshPort,
                         "paths": s.paths.split(whereSeparator: { ",\n".contains($0) })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }] as [String: Any]
                    },
            ] as [String: Any],
        ]
        do {
            let base = ConfigWriter.readRaw(config.configPath) ?? [:]
            let merged = ConfigWriter.applying(edits, to: base)
            try ConfigWriter.write(merged, to: config.configPath)
            _ = config.reloadIfChanged()
            let c = config.currentSnapshot()
            let fieldIssues = c.issues
            let fileIssues = config.fileIssues
            if fieldIssues.isEmpty, fileIssues.isEmpty {
                saveResult = L("已保存并生效（配置已热加载）", "saved and applied (hot-reloaded)")
            } else {
                saveResult = L("已保存，但有字段被回退：", "saved with issues:") + "\n"
                    + (fieldIssues + fileIssues).map { "· \($0.field)：\($0.reason)（\($0.hint)）" }
                    .joined(separator: "\n")
            }
        } catch {
            saveResult = L("写入失败：", "write failed: ") + error.localizedDescription
        }
    }

    /// 丢弃编辑，从当前生效配置重载表单
    func reload() {
        let fresh = SettingsModel(config: config)
        zhipuProviderPath = fresh.zhipuProviderPath
        zhipuCredPath = fresh.zhipuCredPath
        zhipuManualKeys = fresh.zhipuManualKeys
        codexEnabled = fresh.codexEnabled
        codexAuthPath = fresh.codexAuthPath
        codexProxyHost = fresh.codexProxyHost
        codexProxyPort = fresh.codexProxyPort
        kimiEnabled = fresh.kimiEnabled
        kimiCredPath = fresh.kimiCredPath
        mimoEnabled = fresh.mimoEnabled
        mimoCachePath = fresh.mimoCachePath
        ccEnabled = fresh.ccEnabled
        ccRefreshUsage = fresh.ccRefreshUsage
        ccTimeout = fresh.ccTimeout
        ccServers = fresh.ccServers
        language = fresh.language
        refreshInterval = fresh.refreshInterval
        yellow = fresh.yellow
        red = fresh.red
        saveResult = nil
    }

    /// 用系统默认编辑器打开 config.json（不存在则先落一份当前生效配置）
    func openConfigFile() {
        if ConfigWriter.readRaw(config.configPath) == nil {
            let c = config.currentSnapshot()
            try? ConfigWriter.write(c.sanitizedRoot, to: config.configPath)
            _ = config.reloadIfChanged()
        }
        NSWorkspace.shared.open(config.configPath)
    }
}
