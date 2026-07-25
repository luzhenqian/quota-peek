# QuotaPeek / 余量

**所有大模型额度，一眼看清。**

QuotaPeek 是一个本地优先的 macOS 菜单栏与桌面悬浮工具，把 Codex（ChatGPT）、Claude、Kimi、GLM Coding Plan、Grok 的订阅余量、额度窗口与刷新时间集中在一处显示。数据全部通过官方 CLI / 接口在本机获取，不经过任何第三方服务器。

<img src="docs/screenshot.png" alt="QuotaPeek 悬浮面板" width="360">


## 功能

- **菜单栏图标**实时显示最紧张的额度状态。
- **可置顶、可跨桌面的悬浮面板**，适合长时间挂在屏幕角落。
- **智能推荐**：各家额度到期不结转，没用完就浪费。QuotaPeek 会给每家「头号指标」（有月额度看月，没有就看周）算一个「剩余量 × 刷新紧迫度」的分数，自动把最该优先使用的 Provider 卡片置顶，并标出「⚡ 推荐优先使用」。
- **多账号**：同一个 Provider 可以添加多个账号（比如公司 + 个人两个 Claude 订阅），各自独立刷新、独立参与排序和提醒；账号凭证按账号分别存储，互不影响。
- 每个卡片显示：
  - **套餐徽标**，按各家真实层级分色 —— 顶级金色、高端紫、中端蓝、基础灰。
  - **数据源彩色标签** —— 官方 API（绿）、本地 RPC（蓝）、官方 CLI（紫）、本地缓存（橙）。
  - 额度窗口按**月 > 周 > 5 小时**等重要性排序，头号指标用更大字号、更粗进度条突出显示。
  - 进度条按**已用量**填充（越用越满、越红），刷新时间统一显示为「X 天 Y 小时后刷新」。
- 额度低于 **10% / 20% / 25%** 阈值时发送本地通知。
- 自动刷新、本地缓存、错误状态保留（接口临时失败时仍显示上一份好数据）。
- 凭证只存本机：GLM API Key 与 Grok Cookie 存 macOS 钥匙串，Kimi 网页登录态存 WKWebView 持久存储。

## 各家数据来源

QuotaPeek 不保存账号密码，也不把凭证或额度上传到任何服务器。

| Provider | 数据源 | 前置条件 |
| --- | --- | --- |
| **Codex** | 官方 `codex app-server` 的 `account/rateLimits/read`（本地 RPC） | 安装 Codex CLI 并登录 |
| **Claude** | 官方 Claude Code `/usage`（官方 CLI） | 安装 Claude Code 并登录 Pro/Max 订阅 |
| **Kimi** | 默认走官方 Kimi CLI `/usage`（5 小时 / 每周）；在设置中登录 Kimi 网页账号后，改走官方会员接口（**额外显示套餐名与月度总额度**） | 安装 Kimi CLI 并登录；网页接口需在设置中登录一次 |
| **GLM** | Coding Plan `/api/monitor/usage/quota/limit`（官方 API） | 在设置中保存 Coding Plan API Key |
| **Grok** | grok.com `/rest/rate-limits`（官方 API，按模型的请求次数额度） | 在设置中粘贴从浏览器复制的 grok.com Cookie |

### 关于 Grok 的数据源

Grok 没有官方 CLI，订阅额度只在 grok.com 网页可查，而 xAI 用 **Cloudflare bot 防护**会拦截 app 内嵌 WebView（且 Google 登录也拒绝内嵌 WebView）。但 Cloudflare **只拦浏览器 challenge、不拦纯 API 调用**，所以 QuotaPeek 改用 `URLSession` 直连 `/rest/rate-limits`，带你从浏览器复制的登录 Cookie（存 macOS 钥匙串）。

- Grok 按**请求次数**计额度，每个模型独立配额（免费层：Grok 4 每 24h 7 次、Grok 3 30 次、Grok 4 Heavy 每 2h 20 次；SuperGrok 订阅数值更高）。卡片直接显示 `剩 7/7` 原始次数。
- 徽标按订阅层级分色：**Free**（灰）/ **SuperGrok**（紫），查 `/rest/subscriptions` 判断。
- 获取 Cookie：浏览器登录 grok.com → 开发者工具（⌥⌘I）→ Network → 刷新 → 点任一 grok.com 请求 → Request Headers → 复制整段 Cookie 值粘贴到设置。**Cookie 会过期**，失效后卡片会提示，重新复制一次即可。

### 关于 Kimi 的两条数据源

Kimi CLI 的 `/usage` 只暴露 5 小时和每周两档，拿不到套餐名和月度总额度 —— 那两项只存在于 Kimi 网页会员接口。因此 QuotaPeek 支持在设置里登录一次 Kimi 网页账号（内嵌 WebView，用你平时的短信/微信/Google 方式登录）：

- 登录后 Kimi 卡片改用官方会员接口，一次显示 **每月 / 每周 / 5 小时** 额度与 **套餐名徽标**，数据源标签变为绿色「官方 API」。
- token 刷新完全交给 Kimi 网页会话自身完成（access token 30 天、refresh token 90 天），QuotaPeek 不复刻其登录/刷新协议。
- 登录态持久保存在本机 WKWebView 数据存储，不上传。90 天内无需重新登录。
- 未登录时行为不变，仍走官方 CLI。

### 关于 Codex 卡片

普通 ChatGPT 网页聊天的模型消息数没有稳定的公开查询接口，因此 Codex 卡片显示的是 ChatGPT 套餐内的 Codex / Agentic 额度，不代表普通对话的剩余消息数。

## 下载安装

从 [Releases](https://github.com/luzhenqian/quota-peek/releases) 下载最新的 `QuotaPeek.dmg`，打开后把 **余量.app** 拖进「应用程序」即可。发布版经过 Developer ID 签名与 Apple 公证，双击直接打开。

> QuotaPeek 是菜单栏 App（无 Dock 图标）。启动后在屏幕右上角菜单栏找它的仪表盘图标。
>
> 想自己出签名+公证的发布版，见 [`docs/RELEASING.md`](docs/RELEASING.md)。（App Store 因沙盒与「调用本机 CLI」的架构冲突无法上架，故走 Developer ID 直接分发。）

## 系统要求

- macOS 14 或更高版本
- 对应 Provider 的官方 CLI（按需安装）
- 从源码构建需 Swift 6.2+（或 Xcode 26+）

## 构建与运行

调试构建：

```bash
swift build
swift test
swift run QuotaPeek
```

生成可双击运行的 `.app`：

```bash
chmod +x scripts/build-app.sh scripts/run-app.sh
scripts/build-app.sh
open dist/QuotaPeek.app
```

> 开发构建使用 ad-hoc 签名。正式分发前需替换为 Developer ID 签名并公证。

## 配置

首次启动后点菜单栏图标 → 弹窗底部「设置」：

1. 关闭不需要监控的 Provider。
2. CLI 路径通常留空即可自动检测；也可填绝对路径。
3. **Kimi 网页账号**：点「登录 Kimi 网页账号」，用平时的方式登录一次，即可显示套餐名与月度额度；点「退出登录」回退到 CLI。
4. **GLM**：填写 Base URL（`https://open.bigmodel.cn` 或 `https://api.z.ai`）并保存 Coding Plan API Key。
5. **Grok**：从浏览器开发者工具复制 grok.com 的 Cookie 粘贴保存（详见上方「关于 Grok 的数据源」）。
5. 设置刷新间隔、低额度阈值、是否启动即显示悬浮面板。

如果 GLM 凭证已配置在 `~/.claude/settings.json` 的 `ANTHROPIC_AUTH_TOKEN` 中，QuotaPeek 也会自动读取该本地配置。

### 多账号

在设置页对应的 Provider 区块点「+ 添加账号」，并为账号起一个便于区分的名称（如「工作」或「个人」）。Codex、Claude、Kimi 会创建由 QuotaPeek 管理的隔离 CLI 登录目录并打开 Terminal，像平时一样登录一次即可；Kimi 账号创建后还可在账号行点「追加网页登录」，为该账号启用套餐名和月度额度。GLM、Grok 则在添加账号时分别填写 API Key、Cookie。

每个账号可单独启停和改名。GLM API Key 与 Grok Cookie 按账号分别保存在 macOS 钥匙串，Kimi 网页会话也按账号隔离。删除账号会同时移除该账号在 QuotaPeek 中的配置与缓存，并清理它由 QuotaPeek 保存的密钥、专用 CLI 登录目录和 Kimi 网页数据；若要恢复，需要重新添加并登录或填写凭证。升级前已有的默认 CLI 登录目录不会因删除迁移出的默认账号而被删除。

## 项目结构

```text
Sources/QuotaPeek/
├── App             应用状态、菜单栏与悬浮窗口
├── Domain          统一额度模型、套餐分级、偏好与解析工具
├── Infrastructure  进程执行、Keychain、本地缓存、Kimi 网页会话
├── Providers       Codex、Claude、Kimi(CLI/网页)、GLM、Grok 适配器
└── UI              Dashboard 与设置界面
```

每个数据源都实现同一个 `ProviderProbe` 协议，由 `ProviderFactory` 组装、`AppModel.refreshAll` 并发拉取。新增 Provider 只需实现一个 probe 并在工厂里注册，无需改动 Dashboard。

设计与实现文档见 [`docs/superpowers/`](docs/superpowers/)。

## 隐私

- 不收集、不上传任何账号凭证或额度数据；所有请求都在本机发起。
- GLM API Key 存 macOS 钥匙串；Kimi 网页登录态存本地 WKWebView 数据存储。
- 各家额度接口部分为非公开接口，可能随对方改版而失效 —— 届时对应卡片会显示错误并保留上一份缓存，不影响其它 Provider。

## 商标与素材

各 Provider 的名称与图标（OpenAI、Claude/Anthropic、Kimi/Moonshot、智谱 GLM）为其各自所有者的商标，此处仅用于标识对应服务。品牌图标取自 [LobeHub 图标库](https://github.com/lobehub/lobe-icons)。本项目与上述任何公司均无隶属或背书关系。

## 贡献

欢迎 issue 与 PR。改动请附带：

- `swift build` 通过、`swift test` 全绿；
- 新增解析逻辑请补对应的解析单测（见 `Tests/QuotaPeekTests/ProviderParserTests.swift`）。

## License

[MIT](LICENSE)
