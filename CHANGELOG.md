# Changelog

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 SemVer。

## [未发布]

### 新增

- **Cursor 订阅渠道（magpie）**：跑 `magpie quota <provider> --json`（argv 直传不经 shell，
  凭据留在 magpie，CLI 自带 1 分钟缓存）。**多 provider**：`magpie.providers` 列表
  （兼容旧 `provider` 单值，默认 `["cursor"]`），每个 provider 一个独立身份——
  cursor / grok (SuperGrok) / codex / zhipu-glm / kimi-code-cn / deepseek…，与原生渠道
  重名的显示名带 (magpie) 后缀。窗口是各家自有口径（Cursor 4 窗口 / SuperGrok 7 天 /
  智谱 5h+7d+MCP），聚合口径（Total）不参与主值，进度条放最紧张的两个窗口并下发窗口
  短名（Other / Grok / 5h / 7d / MCP…）作为条标签。`magpie.binPath` 显式路径（默认按
  常见安装位自动寻找，launchd 环境无用户 PATH）、`magpie.enabled` 开关。
- 设置页新增 "Magpie（Cursor / Grok…）" 来源卡片（启用开关 + CLI 路径 + providers 列表）。
- Cursor 品牌 logo（simple-icons）。
- **Claude Code 本机模式**：`claudeCode.local.enabled` 开启后多一个 "CC 本机" 行——读本机
  `~/.claude.json`，与远端 SSH 模式共用解析；CC 切到本机跑时不再需要 SSH。默认 best-effort
  跑本地 `claude -p /usage` 刷新（找不到 CLI 就跳过）；`local.refreshUsage` 可单独关成纯被动
  （代理只配在终端会话、launchd 无代理变量的环境）。**多账号接力**：`local.extraProfiles`
  可挂更多本机 profile（如 et 的 `~/.claude-profiles/et/.claude.json`），每个一条被动行
  （`CC <name>`，extras 恒不拉探针，与默认路径相同的条目自动去重）。设置页 CC 卡片新增开关。
- **Kimi 凭据缺失/过期自动经 magpie 兜底**：本地 `~/.kimi-code` 凭据缺失或 token 过期时，
  自动改查 `magpie quota kimi-code-cn --json`（magpie 自管凭据，不经 kimi CLI 用 Kimi——
  其他设备/代理在跑——也能查到），行名保持 Kimi 不产生第二行；magpie 里也没有 kimi 账号时，
  提示同时给出两条路径。无需把 kimi-code-cn 加入 `magpie.providers`（那是 magpie 独立行的开关）。

### 修复

- **CC 本机数据长期不更新**：探针子进程缺 `USER` 环境变量时，claude 取不到钥匙串里的订阅
  凭据，静默退化成无订阅态输出且不写缓存；现在探针补齐 `USER`/`HOME` 并清掉继承的
  `CLAUDE_CONFIG_DIR`。stdin 改接 `/dev/null`（CLI 否则空等 3s）。`extraProfiles[]` 支持
  profile 级 `refreshUsage` + `claudePath`，用该号自己的二进制和 `CLAUDE_CONFIG_DIR` 探针
  （出口按进程路径钉定的环境下不会走错链路）。CC 用量快照的 ⚠ 停更线从 24h 收紧到 1h。

### 变更

- **面板数字减负**：进度条不再在条尾重复标百分比（最大窗口的条尾值与右上角大号主值
  恒等，非最大窗口看条长与颜色即可，精确值保留在 VoiceOver 标签）；标签列收窄、条体
  加宽。每行数字从 ~5 组降到主值 + 重置/更新行。
- **logo 上品牌色**：放弃 v2 的全灰单色模板渲染，改为模板位 + 品牌识别色着色——小米橙
  #FF6900、Claude 赭 #D97757；纯黑白 mark（OpenAI/Kimi/Cursor/智谱）深浅模式自适应
  近黑/近白。面板统一行与吸边条同规则。
- 智谱 logo 更正为开放平台官方 "Z" 字标（自 z.ai 官方 logo.svg 提取字形，单 path 矢量）；
  此前的点阵图案（lobehub zhipu 图标）并非现行品牌标。

## [2.0.0] - 2026-10-12

产品级 v2：正确性底座 + SwiftPM 拆分 + 首屏信息层级 + 开源工程资产。规格见
`docs/superpowers/specs/2026-10-12-quotadock-product-v2-design.md`。

### 修复（v1 关键缺陷）

- **智谱临时故障不再永久禁用有效 key**：v1 任何非 200（含一次 429 限流、5xx 抖动）都会把
  key 尾号写入 skip 文件永久跳过；现在只有 401/403、或 200 响应明确"身份验证失败"（code 1000）
  才算确认失效，429/5xx/解析异常一律保留最近成功值并自动重试。
- **配置热加载**：v1 启动读取一次（README 却声称"等下一轮刷新生效"）；现在每 5 秒内容哈希检测，
  有效变更在下一个刷新边界整体应用，坏文件保留上一份有效配置。
- **智谱结果改稳定身份合并**：v1 按数组索引回写，配置重排/慢回调竞争会写错行；现在
  provider:pid#尾号 / individual / manual:显式id 是唯一主键。
- **SSH 远端命令注入面收敛**：servers[].host/user/paths 白名单校验 + 单引号转义，
  拼接注入形态在配置层直接拒绝。
- **paths 配置双格式兼容**：v1 代码按 `[{path:…}]` 读、示例给字符串数组（静默失效），
  现在两种都支持。
- 重启后首屏直接显示上次会话的最近可信值（版本化缓存，标注缓存时间）。

### 新增

- **大屏仪表盘窗口**（面板 📈 按钮）：环形仪表（最紧张项）+ 服务概览 + 7 天用量趋势折线
  （按数据源固定配色）+ 重置时间轴（5h=实心点/周=空心环，now→+7d）；趋势来自本地
  HistoryStore（每次刷新成功采样一个点，保留 7 天，~/.cache/quotadock/history.json，
  只含百分比无凭据）。渲染模式 QUOTADOCK_DASHBOARD=1 且隔离临时目录不污染真实数据。
- **悬停 Peek 交互**：默认收纳为吸边条（记住边与沿边位置）；悬停 0.35s 展开预览、
  离开 2.5s 自动收回；点击/拖动/开设置=固定展开；展开面板锚定吸边条原位。
- **设置窗口**（面板齿轮按钮）：按 连接来源 → 验证 → 显示偏好 组织；表单编辑路径/开关/
  CC 服务器/手工 key，保存深度合并写回 config.json（保留未知字段）并立即热加载回显校验结果；
  每个来源有状态点和单源"验证"（强制抓取）按钮。
- 总览摘要卡：最紧张服务 + 大号百分比 + 最近重置倒计时 + 更新时间；无数据转引导卡。
- 字号体系与 design tokens（下限 8→9.5pt），悬停设置重组为 来源状态→显示偏好→操作。
- 全量可访问性标注（VoiceOver label / tooltip / 最小点击区域）。
- 手动强制刷新会重探 skip 名单里的身份，成功自动恢复。
- `--version`、版本化 Info.plist、GitHub Actions CI（build/test/bundle/渲染冒烟）、
  issue/PR 模板、发布脚本（zip + SHA-256）、`docs/architecture.md`。
- 52 项单元测试：解析 fixture、错误分类、刷新代次/单飞/节流/合并表、配置校验与热加载、
  缓存与 skip 迁移、shell 安全。

### 架构

- 1426 行单文件拆为 SwiftPM 双 target：`QuotaDockCore`（可测核心）+ `QuotaDock`（App/UI）。
- 数据源协议 `QuotaSource`：新增数据源只需实现协议 + 注册一行，不碰 UI/窗口代码。

## [1.0] - 2026-10-12 之前

- v1.0：多 AI 服务额度吸边仪表盘首版（智谱多 key / Codex / Kimi / MiMo 占位 / 远程 Claude Code，
  悬浮面板 + 吸边细条 + 双语 + 离屏渲染 + 零第三方依赖）。
- v1.x：per-service 刷新节流、SSH 复用、非阻塞重试、MiMo 被动缓存源、CC 远程 /usage 刷新。
