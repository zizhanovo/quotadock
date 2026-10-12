# QuotaDock 产品级 v2 设计规格

## 背景

QuotaDock 是一个 macOS 常驻 AI 服务额度仪表盘。当前版本已经覆盖智谱 Coding Plan、Codex、Kimi、MiMo 占位和远程 Claude Code，并支持悬浮面板、吸边细条、双语、离屏渲染和零第三方依赖。

本次升级的目标是让项目同时具备更高的运行可信度、更低的维护成本、更清楚的首屏体验和更完整的开源传播资产，从而提高真实使用留存与 GitHub star 转化。范围覆盖数据层、刷新调度、配置、UI/UX、测试、构建发布和文档，但不新增与额度监控无关的产品面。

### 现状证据

- `main.swift` 约 1354 行，配置、凭据解密、所有数据源、缓存、SwiftUI 视图、窗口生命周期和离屏渲染全部在一个文件中。
- `Conf.shared` 在进程启动时读取一次配置；README 当前声称“改完等下一轮刷新即生效”，与实现不一致。
- `Store.refreshAll` 为服务启动异步任务，但没有刷新代次、取消或单飞保护；智谱结果按数组索引回写。
- 任意非 200 的智谱响应都会写入 skip 文件，临时的 429/5xx 可能被永久当成失效 key。
- 面板宽度固定为 232，核心文字大量使用 8–11pt；当前截图展示了高密度的平级信息，但没有首要风险摘要。
- 仓库没有测试目标、CI、版本化 app bundle 元数据、发布包、贡献指南或 issue/PR 模板。

## 成功标准

### 产品

1. 第一次打开面板时，用户在 3 秒内能回答“哪个额度最紧张、数据是不是新鲜、下一次什么时候重置”。
2. 临时网络、限流或服务端故障不会清掉可信的旧数据，也不会永久禁用有效 key。
3. 增加一个新额度数据源时，只需要实现数据源协议、解析 fixture 和一条集成注册，不接触 SwiftUI 或窗口代码。
4. 新用户可以在 README 中用 30 秒理解用途，用 2 分钟完成安装，遇到常见凭据/网络问题能找到下一步。

### 工程

1. `swiftc` 在干净 macOS 环境构建成功；测试目标可单独运行。
2. 核心解析、错误分类、刷新去重、缓存新鲜度和配置校验都有确定性测试。
3. 暗色/亮色面板和 top/bottom/left/right 吸边条拥有离屏截图回归基线。
4. 发布产物包含 app bundle、版本号、Info.plist、校验和以及清晰的变更记录。

## 非目标

- 不引入联网账号系统、云端同步、遥测或第三方分析。
- 不把凭据上传到 QuotaDock 自有服务；所有凭据读取仍在本机完成。
- 不在本轮实现完整的 MiMo 登录流程；MiMo 继续作为安全的缓存/占位数据源，直到有稳定且可验证的会话来源。
- 不把项目改造成跨平台应用；macOS 原生体验和零运行时依赖继续保留。

## 目标架构

保持单一可执行入口，但按职责拆成 Swift 文件（后续可迁移到 SwiftPM target）：

```text
Sources/QuotaDock/
  App/
    QuotaDockApp.swift          # 入口、NSApplication、NSPanel 生命周期
    WindowCoordinator.swift     # 展开/收起、拖动、吸边、位置恢复
  Core/
    Models.swift                # QuotaSnapshot、QuotaWindow、SourceStatus
    QuotaSource.swift           # 数据源协议和 SourceID
    RefreshCoordinator.swift    # 并发、取消、节流、代次、合并
    FreshnessPolicy.swift       # 新鲜/缓存/过期/停更策略
  Configuration/
    ConfigurationStore.swift    # schema、默认值、校验、文件监听、重载
  Sources/
    ZhipuSource.swift
    CodexSource.swift
    KimiSource.swift
    MiMoSource.swift
    ClaudeCodeSource.swift
  Persistence/
    CacheStore.swift             # UserDefaults/文件缓存的版本化读写
    SkipListStore.swift          # 仅保存确认失效的稳定身份
  UI/
    DashboardView.swift
    SummaryView.swift
    SourceRowView.swift
    EdgeStripView.swift
    SettingsView.swift
    DesignTokens.swift
  Support/
    LocalizedCopy.swift
    TimeFormatting.swift
    Logger.swift
Tests/QuotaDockTests/
```

### 核心契约

```swift
enum SourceID: String, Hashable { case zhipu, codex, kimi, mimo, claudeCode }

protocol QuotaSource {
    var id: SourceID { get }
    func fetch(configuration: SourceConfiguration,
               cancellation: CancellationToken) async -> SourceResult
}

struct SourceResult {
    let source: SourceID
    let snapshots: [QuotaSnapshot]
    let status: SourceStatus
    let observedAt: Date
}
```

`QuotaSource` 只负责读取凭据、请求或读取本地快照、解析响应并返回领域模型。它不能更新 SwiftUI 状态、写窗口位置或直接读写全局配置。`RefreshCoordinator` 按 `SourceID + identity` 合并结果，并将每轮刷新绑定到一个代次；旧代次的回调不得覆盖新代次。

### 刷新与错误状态

每个数据源拥有独立的 `refreshInterval`、超时和缓存策略。协调器保证同一数据源同一时间最多有一个请求；手动刷新会取消该源的旧任务并开启新代次。合并规则如下：

| 状态 | UI 表现 | 是否写入 skip |
|---|---|---|
| success | 显示新值和 observedAt | 否 |
| network/timeout | 保留最近成功值，标注“网络暂时不可用” | 否 |
| rateLimited (429) | 保留最近成功值，显示重试时间 | 否 |
| serverError (5xx) | 保留最近成功值，显示服务端错误 | 否 |
| unauthorized/invalidCredential | 清除该身份的数字，标注“凭据失效” | 仅确认身份失效时 |
| invalidPayload | 保留旧值，记录诊断信息 | 否 |
| noDataYet | 显示引导动作 | 否 |

智谱 key 的合并主键改为稳定身份标识（优先 provider ID + key tail，手工 key 使用显式配置 ID）；禁止仅按数组索引回写。重复 host、重复尾号和重命名不会导致结果串行覆盖。

### 配置与缓存

`ConfigurationStore` 负责：

- 读取 JSON、填充默认值并校验阈值、路径、刷新间隔和服务配置。
- 监听文件修改时间；有效变更在下一个安全刷新边界应用，刷新中的请求不被半途改写。
- 校验失败时保留上一份有效配置，并向 UI 返回具体字段、原因和修复提示。
- 将所有路径展开、语言、时区和代理设置集中处理，数据源不再直接访问 `Conf.shared`。

缓存采用版本化记录：`source`, `identity`, `snapshot`, `observedAt`, `expiresAt`, `schemaVersion`。缓存可用于显示最近可信值，但必须明确标出缓存时间；缓存中禁止写入原始 token、API key 或 SSH 凭据。

远程 Claude Code 的 SSH 命令参数需要经过安全转义；服务器 host 使用参数数组传递，远程路径采用严格允许字符或安全编码，避免拼接不受控 shell 片段。

## UI/UX 设计

### 信息层级

面板顺序固定为：

1. **总览摘要**：最紧张服务、使用百分比、颜色状态、最近更新时间和最近重置窗口。
2. **服务列表**：按最大使用百分比降序；每行包含品牌/名称、主值、5h 与周窗口、数据状态。
3. **次要操作**：刷新、显示筛选、剩余/已用切换、展开设置和退出。

摘要只回答一个问题：“现在最需要关注什么”。没有有效数据时，摘要变成引导卡，告诉用户缺哪个配置、如何修复以及是否可以继续使用缓存。

### 视觉方向

保留悬浮卡片和吸边细条的识别度，但建立统一 design tokens：背景材质、主文本、次文本、分隔线、成功/警告/危险色、圆角、内外间距和字号。字号下限提高到系统可读范围，减少全局胶囊和过多边框；只让当前最紧张项使用更强的颜色和权重。

进度条继续使用“已用百分比”语义；当用户切换“剩余”时只改变数字，不改变颜色阈值和排序，避免同一颜色在不同模式下代表相反含义。状态颜色同时配合文字和图标，不能只依赖颜色。

吸边条保留四边吸附和多实例角标，但每项加入 VoiceOver label、tooltip 和稳定品牌标识；没有数值的服务展示状态图标与名称，不用单独的 ❌ 作为唯一信息。

### 可访问性与文案

- 所有按钮有 `accessibilityLabel`、`help` 和最小点击区域；刷新、展开、收起、设置和退出可用键盘触达。
- 中英文文案集中在 `LocalizedCopy`，不在视图中散落硬编码的“周”“重置”“立即刷新”等字符串。
- 错误文案使用“发生了什么 + 现在能做什么”的句式，例如“Codex 暂时无法连接；保留了 14:20 的数据，稍后会自动重试”。
- 首次运行不要求用户先理解 provider 配置内部结构；设置页按“连接来源 → 验证 → 显示偏好”顺序组织。

## 测试与验证

### 单元测试

- quota JSON 的正常、缺字段、窗口顺序变化和单位回退解析。
- HTTP 状态到 `SourceStatus` 的分类，特别是 200 无效 payload、401/403、429、5xx 和网络超时。
- 刷新代次、取消、单飞、节流、旧结果拒绝覆盖和重复身份合并。
- 配置默认值、非法阈值、路径展开、热加载失败回滚。
- 缓存新鲜度、过期标注、敏感字段不落盘。
- 时间格式化、时区、剩余/已用百分比语义。

### 视觉与集成验证

- `QUOTADOCK_RENDER=1` 生成亮色/暗色面板截图。
- 四个吸边方向和无数据、缓存、失效、停更状态截图回归。
- 构建脚本在临时目录生成完整 app bundle，检查 `Info.plist`、资源和可执行文件。
- GitHub Actions 运行 typecheck、测试、构建和截图 smoke check。

## 开源与发布

新增：

- `Info.plist`、版本号来源和 `--version` 输出。
- `README` 首屏 30 秒演示、动图/短视频、支持矩阵、隐私边界、配置向导、故障排查和贡献指南。
- `.github/workflows/ci.yml`、`.github/ISSUE_TEMPLATE/`、`.github/pull_request_template.md`。
- `CHANGELOG.md` 和发布脚本：zip、SHA-256、版本说明。
- `docs/architecture.md`：数据流、数据源契约、缓存/错误状态和新增数据源步骤。

发布说明要明确：QuotaDock 是本地只读仪表盘，哪些服务读取本地凭据，哪些服务通过网络请求，哪些服务只读远程缓存；不要用“安全”“实时”等无法证明的绝对表述。

## 迁移与阶段

1. **阶段 1：正确性底座**：领域模型、错误分类、身份 ID、刷新协调器、配置校验和缓存接口；保留现有 UI 作为适配层。
2. **阶段 2：拆分与测试**：将数据源和窗口职责移入独立文件/target，加入 fixture、单元测试和离屏状态覆盖。
3. **阶段 3：首屏与可访问性**：摘要层级、统一 tokens、文案集中、设置/错误引导、吸边条可访问性。
4. **阶段 4：发布与增长**：bundle 元数据、CI、README/演示、贡献模板、版本发布资产。

每阶段都必须保持可构建；阶段之间不引入需要用户迁移凭据的破坏性变更。若新配置 schema 不兼容，必须提供默认回退和迁移提示。

## 风险与取舍

- 拆分文件会暂时增加类型和依赖的显式传递，但这是支持新数据源和独立测试的必要成本。
- 配置热加载可能让用户误以为凭据已生效；UI 必须显示“已加载时间”和验证结果。
- 更高字号可能使面板变高；通过摘要、折叠次要信息和更好的排序控制总高度，而不是继续压缩文字。
- 继续零依赖意味着不使用第三方图表/网络库；复杂度放在内部契约和测试，而不是运行时依赖。

