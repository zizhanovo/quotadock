# QuotaDock 架构

> 面向贡献者。产品视角的介绍看 [README](../README.md)，v2 设计规格看
> `superpowers/specs/2026-10-12-quotadock-product-v2-design.md`。

## 总览

QuotaDock 是 **macOS 本地只读**的多 AI 服务额度仪表盘：常驻悬浮面板 + 吸边细条，
零第三方运行时依赖，SwiftPM 双 target：

```text
Package.swift
Sources/QuotaDockCore/        ← 可测核心（库）
  Core/         Models · QuotaSource 协议 · RefreshCoordinator · 错误分类 · 解析 · 新鲜度
  Configuration/  ConfigurationStore（schema 校验 + 热加载）
  Persistence/    CacheStore（版本化快照缓存） · SkipListStore（失效身份名单）
  DataSources/    Zhipu · Codex · Kimi · MiMo · ClaudeCode
  Support/        ShellSafety · LocalizedCopy · TimeFormatting · Logger
Sources/QuotaDock/           ← App（可执行）
  App/          Store（UI 适配层） · AppDelegate · WindowDrag
  UI/           DashboardView · SummaryView · SourceRowView · EdgeStripView · SettingsView · DesignTokens
  main.swift    入口（含 QUOTADOCK_RENDER 离屏渲染模式） · Version.swift
Tests/QuotaDockTests/         ← 52 项单元测试
```

## 数据流

```text
config.json ──5s 内容哈希──▶ ConfigurationStore ──revision+1──▶ Store（重排定时器）
                                    │ 快照值传递（在飞请求不被半途改写）
                                    ▼
                          RefreshCoordinator（@MainActor）
                    代次 · 单飞 · per-identity 节流 · 合并表
                     │                              ▲
                     ▼                              │ SourceResult
              QuotaSource.fetch(async)   ───────────┘
              （读本地凭据/发请求/解析，不碰 UI/窗口/全局态）
                     │ success
                     ▼
              CacheStore（重启恢复首屏）
                     │
                     ▼
              Store.outcomes → keyQuotas/extras 行模型 → SwiftUI
```

## 核心契约

### 数据源协议

```swift
protocol QuotaSource {
    var id: SourceID { get }
    func identities(configuration: AppConfiguration, includeSkipped: Bool) -> [SourceIdentity]
    func fetch(configuration: SourceConfiguration, cancellation: CancellationToken) async -> SourceResult
}
```

- **身份（SourceIdentity）**是全局稳定主键：`zp:provider:<pid>#<尾号>`、`cc:<host>`、
  `codex:default`……缓存、skip、合并、UI 行 id 全部以它为准。重命名、重复尾号、
  配置重排不会串数据。
- 数据源只做三件事：读凭据 → 请求/读本地快照 → 返回领域模型。**不许**碰 SwiftUI 状态、
  窗口位置或全局配置（配置经 `SourceConfiguration` 值传入）。
- 身份里**不携带密钥**；fetch 时从凭据文件重新解析。

### 刷新与合并表（RefreshCoordinator）

| 状态 | 快照处理 | UI 表现 | 写 skip |
|---|---|---|---|
| success | 更新 + 写缓存 | 新值 + observedAt | 否 |
| network / timeout | 保留最近成功值 | "暂时无法连接，保留了 HH:mm 的数据" | 否 |
| rateLimited (429) | 保留 | "接口限流…稍后重试" | 否 |
| serverError (5xx) | 保留 | "服务端错误（503）…" | 否 |
| invalidPayload | 保留 + 诊断 | "响应异常，保留了 HH:mm 的数据" | 否 |
| credentialStale | 保留 | 引导文案（跑一次 CLI 续期） | 否 |
| unauthorized(confirmed) | 清除 | "凭据失效" | **是** |
| noDataYet | 不动 | 引导动作 | 否 |

- **代次**：手动强制刷新 bump generation 并取消所有在飞任务；旧代次的迟到结果直接丢弃。
- **单飞**：同一身份同一时间最多一个请求。
- **节流**：per-identity `refreshIntervalSeconds`（下限 30s）。
- **skip 重探**：强制刷新把 skip 名单里的身份重新枚举；成功即自动移出（恢复路径）。
- `credentialStale` 与 `unauthorized(confirmed)` 的区别：前者可由用户动作恢复
  （Kimi token 15 分钟过期 → 跑一次 kimi CLI；Codex OAuth 过期 → 跑 codex），
  保留缓存值；后者是服务端明确拒绝该身份。

### 配置（ConfigurationStore）

- 启动读一次；每 5s 对比文件**内容哈希**（APFS 上 setAttributes mtime 不可靠，已实测），
  变化即校验 → 整体替换 revision+1 → 主线程回调。
- 字段级校验：非法值回退默认 + `ConfigIssue`（字段/原因/修复提示），配置整体仍可用。
- 整文件坏（JSON 解析失败）：保留上一份有效配置，`fileIssues` 暴露问题。
- SSH 相关（host/user/sshPort/paths）在配置层白名单校验；数据源侧 `ShellSafety`
  单引号转义为纵深防御。
- **写回**（设置窗口保存）：`ConfigWriter` 深度合并编辑进文件原始 dict（未知字段保留），
  pretty + 排序键原子写，随后立即热加载。手编 JSON 与设置窗口双向互通。

### 缓存与 skip

- `CacheStore`：`~/.cache/quotadock/quota-cache.json`，记录
  `{schemaVersion, source, identityKey, displayName, snapshot, observedAt, expiresAt}`；
  版本不匹配整体作废。`QuotaSnapshot` 按构造不含 token/key——缓存面天然无敏感字段。
- `SkipListStore`：`~/.config/quotadock/skip-v2.json`（稳定身份）；
  v1 的 `quotadock-skip.txt` 尾号文件只读迁移（含 `individual` 哨兵）。

## 新增一个数据源的步骤

1. `Sources/QuotaDockCore/DataSources/` 新建 `XxxSource.swift`，实现 `QuotaSource`
   （身份枚举 + fetch + 解析；解析写成纯函数并配 fixture 测试）。
2. 在 `App/Store.swift` 的默认 sources 数组注册一行。
3. 需要配置项的话：`config.example.json` 加默认值；`ConfigurationStore.sanitize`
   加字段级校验（有约束就加）。
4. 测试：解析 fixture、错误分类映射、（有节流语义则）协调器交互。
5. 视图零改动——行由 `Store.rebuildRows` 统一生成。品牌 logo 放 `logos/<id>.svg|png`
   并在 `EdgeStripView.logoID` 加一条前缀映射。

## 验证

```bash
swift build && swift test          # 单元测试
./build.sh                          # release bundle（Info.plist 版本化）
QUOTADOCK_RENDER=1 QUOTADOCK_LOGOS=$PWD/logos .build/debug/QuotaDock        # 亮色
QUOTADOCK_RENDER=1 QUOTADOCK_DARK=1 QUOTADOCK_LOGOS=$PWD/logos ...           # 暗色
QUOTADOCK_RENDER=1 QUOTADOCK_STATE=empty ...                                  # 空态引导卡
QUOTADOCK_RENDER=1 QUOTADOCK_STRIP=1 QUOTADOCK_EDGE=left ...                  # 吸边条
QUOTADOCK_RENDER=1 QUOTADOCK_SETTINGS=1 ...                                   # 设置窗口
```

截图基线存 `docs/`；CI 对渲染产物做非空 + 尺寸断言（像素级基线跨 macOS 版本会抖动，
只在本地做）。
