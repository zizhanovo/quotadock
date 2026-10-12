# Changelog

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 SemVer。

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
