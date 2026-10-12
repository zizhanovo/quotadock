# QuotaDock

**macOS 多 AI 服务额度吸边仪表盘** —— 一张常驻悬浮卡片聚合你所有 AI 订阅的用量，收起后变成贴屏细条，按紧程度一目了然。单文件 Swift，零第三方依赖，全部行为可配置。

![dashboard](docs/dashboard.png)

## 它监控什么

| 服务 | 数据 | 方式 |
|---|---|---|
| 智谱 Coding Plan（多 key） | 5h 窗口% + 周额度% + 重置倒计时 | 官方监控接口，只读不耗额度 |
| Codex（ChatGPT OAuth） | 周窗口% + credits | 官方用量接口，直连/代理交替重试 |
| Kimi | 5h 窗口% + 周% | 官方套餐接口（读本地 CLI 凭据） |
| MiMo | 占位 | 套餐接口需 App 内会话，待接入 |
| Claude Code（远程 VPS） | 5h% + 周% + 数据时间 | **纯被动零探针**：SSH 读服务器上 Claude Code 真实调用后缓存的用量快照，不发任何额外 API 请求 |

每个服务都可以在配置里单独开关。

## 特性

- **常驻悬浮仪表盘**：时钟 + 每个 key 一节（状态色圆点、5h/周双进度条、重置倒计时）+ 其他服务区
- **收起 = 吸边细条**：靠哪条屏边近就吸哪条——左右吸成竖条、上下吸成横条；每项「彩色百分比 + 品牌 logo」，同 logo 多实例（如多台 VPS）自动加 ①② 角标；点击恢复、拖到别的边换向
- **配色分档**：绿 < 黄阈值 ≤ 黄 < 红阈值 ≤ 红（阈值可配）
- **失效即反馈**：key 被吊销显示 ❌ 不挂旧数字；纯网络抖动才保留旧数据
- **双语界面**：`language: "zh" | "en"` 切换
- **零依赖**：AppKit + SwiftUI 单文件（~1000 行），`swiftc` 直接编译
- key 只在内存中使用，不落盘、不上报

## 安装

需要 macOS 13+ 和 Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone <repo> && cd quotadock
./build.sh --install
```

装完即常驻右上角。卸载：

```bash
launchctl bootout gui/$(id -u)/local.quotadock
rm ~/Library/LaunchAgents/local.quotadock.plist
rm -rf <clone 目录>
```

## 配置

配置文件：`~/.config/quotadock/config.json`（不存在则全部用内置默认值；模板见 [`config.example.json`](config.example.json)，路径可用 `QUOTADOCK_CONFIG` 环境变量覆盖）。改完等下一轮刷新（默认 3 分钟）即生效。

| 字段 | 默认 | 说明 |
|---|---|---|
| `language` | `"zh"` | 界面语言，`"en"` 英文 |
| `timezone` | `"Asia/Shanghai"` | 倒计时/时间展示时区 |
| `refreshIntervalSeconds` | `180` | 刷新间隔 |
| `thresholds.yellow` / `red` | `60` / `85` | 用量配色分档线 |
| `zhipu.providerConfigPath` | `~/.zcode/v2/provider_config.json` | ZCode provider 配置自动发现（没有该文件就跳过） |
| `zhipu.credentialsPath` | `~/.zcode/v2/credentials.json` | ZCode 个人套餐加密凭据 |
| `zhipu.names` | `{}` | providerId → 显示名（如 `{"bigmodel-api-2": "周卡"}`） |
| `zhipu.keys` | `[]` | 手工配置 key：`[{"name": "...", "key": "..."}]`，与自动发现合并去重 |
| `codex.enabled` | `true` | 开关 |
| `codex.authPath` | `~/.codex/auth.json` | Codex CLI OAuth 凭据 |
| `codex.proxyHost` / `proxyPort` | `127.0.0.1` / `6152` | 代理重试路（Clash/Surge 常见端口）；`proxyPort: 0` 禁用 |
| `codex.retries` / `retryIntervalSeconds` | `4` / `15` | 直连/代理交替重试策略 |
| `codex` / `kimi` / `mimo` `.refreshIntervalSeconds` | `180` | 各服务独立刷新间隔（节流，未到期跳过并保留旧数据） |
| `kimi.enabled` / `credentialsPath` | `true` / `~/.kimi-code/...` | Kimi CLI 凭据（token 15 分钟过期，跑一次 `kimi` CLI 自动续期） |
| `mimo.enabled` | `true` | 当前为安全占位 |
| `claudeCode.servers` | `[]` | 远程服务器列表：`{"host": "ssh别名", "name": "显示名", "sshPort": "", "paths": ["/home/claude/.claude.json", "/root/.claude.json"]}`；多路径取快照最新 |
| `claudeCode.sshConnectTimeout` | `6` | SSH 连接超时秒数 |
| `claudeCode.refreshIntervalSeconds` | `600` | CC 服务器刷新间隔（快照只在有人用时才变，默认放宽到 10 分钟） |
| `claudeCode.sshMultiplexing` | `true` | SSH 连接复用（ControlMaster，跳板场景握手开销归零） |
| `autoPing.enabled` / `command` | `false` | 个人套餐 5h 窗口自动敲活命令（见 `glm-ping.swift`） |

凭据类文件（`auth.json`、`kimi-code.json`、SSH key）只在本机读取，QuotaDock 不向任何第三方发送。

## Claude Code 数据源说明（零探针设计）

Claude Code 在真实调用后会把自己的用量快照写进 `~/.claude.json` 的 `cachedUsageUtilization`（5h/周百分比、重置时间、抓取时间）。QuotaDock 只通过 SSH 读这个文件：**有人用就自动新鲜，没人用就如实显示停更时间**（超 24h 标 ⚠），不产生任何额外 API 请求，也不会碰服务器上的凭据。

## 开发

```bash
./build.sh                # 编译
swiftc -O -swift-version 5 -o /tmp/quotadock-render main.swift   # 渲染二进制
# 离屏渲染 UI 效果图（不弹窗，内置 mock 数据）
QUOTADOCK_RENDER=1 QUOTADOCK_DARK=1 QUOTADOCK_OUT=/tmp/d.png /tmp/quotadock-render
QUOTADOCK_RENDER=1 QUOTADOCK_STRIP=1 QUOTADOCK_EDGE=top QUOTADOCK_LOGOS=$PWD/logos QUOTADOCK_OUT=/tmp/s.png /tmp/quotadock-render
```

运行日志：`/tmp/quotadock.out.log`。单文件架构、各数据源逆向结论和踩坑记录见源码注释。

### 性能设计

常驻开销：~40MB 内存、空闲 0% CPU（每 3 分钟一轮网络轮询）。在此之上：

- **各服务独立刷新节流**：Claude Code 快照只在服务器有人用时才变化，默认 600s 才查一次（SSH 进程与握手开销降 2/3）；未到期的轮次跳过并保留上一轮数据，UI 不闪空
- **SSH 连接复用**：ControlMaster/Persist（30 分钟），走跳板机的轮询从全握手降为毫秒级复用
- **重试不占线程**：Codex 的直连/代理交替重试用 asyncAfter 调度，不 Thread.sleep 停线程
- 手动点刷新按钮 = 全部服务强制立即刷新（无视节流）

## License

[MIT](LICENSE)

---

# QuotaDock (English)

A macOS always-on AI quota dashboard that docks to your screen edge. Monitors Zhipu Coding Plan (multi-key), Codex, Kimi, and remote Claude Code instances (passively, zero probe requests — reads the usage snapshot Claude Code itself caches after real calls, over SSH). Single-file Swift, no third-party deps, everything configurable via `~/.config/quotadock/config.json`, bilingual UI (zh/en). Build with `./build.sh --install`.
