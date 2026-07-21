# 发布签名 + 公证的 DMG

QuotaPeek 走 **Developer ID 直接分发**（非 App Store）。因为核心功能是调用本机官方 CLI（codex / claude / kimi / gemini）并内嵌 WebView 登录第三方，与 App Store 的沙盒要求根本冲突，无法上架 —— Developer ID 分发是等价且体验几乎一致的方案（公证后双击即开，无 Gatekeeper 警告）。

## 一、准备（一次性）

需要 **Apple Developer Program** 会员（$99/年）：

1. **Developer ID Application 证书** —— 在 Xcode（Settings → Accounts → Manage Certificates）或开发者网站创建，会自动装进登录钥匙串。
2. **App Store Connect API Key**（用于公证，比 Apple ID 更适合 CI）：
   - App Store Connect → Users and Access → Integrations → App Store Connect API → 生成 Key（角色选 Developer 即可）。
   - 记下 **Key ID** 与 **Issuer ID**，下载一次性的 `AuthKey_XXXX.p8`。

## 二、本地一键出包

```bash
# 只签名（不公证，用于本地测试）：
SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" scripts/release.sh

# 签名 + 公证（推荐）—— 先建一个 notarytool 凭证 profile：
xcrun notarytool store-credentials quotapeek-notary \
  --key AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>

SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
NOTARY_PROFILE=quotapeek-notary \
  scripts/release.sh
```

产物在 `dist/QuotaPeek.dmg`，已签名并 staple 公证票据，可直接分发。

> 若本机有多个同名 Developer ID 证书导致 `ambiguous`，把 `SIGN_IDENTITY` 换成证书的 SHA-1 哈希：
> `security find-identity -v -p codesigning` 取哈希填入。

## 三、CI 自动发布（推 tag 即出 Release）

`.github/workflows/release.yml` 在推送 `v*` tag 时自动构建、测试、签名、公证并创建 GitHub Release。

在 **Settings → Secrets and variables → Actions** 配置：

| Secret | 值 |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | Developer ID 证书 .p12 的 base64（钥匙串导出 .p12 后 `base64 -i cert.p12 \| pbcopy`） |
| `MACOS_CERT_PASSWORD` | 导出 .p12 时设的密码 |
| `MACOS_CERT_IDENTITY` | `Developer ID Application: 你的名字 (TEAMID)` |
| `KEYCHAIN_PASSWORD` | 任意字符串（CI 临时钥匙串口令） |
| `NOTARY_KEY_P8_BASE64` | `AuthKey_XXXX.p8` 的 base64 |
| `NOTARY_KEY_ID` | API Key ID |
| `NOTARY_ISSUER_ID` | App Store Connect Issuer ID |

然后：

```bash
git tag v0.1.0
git push origin v0.1.0
```

Actions 跑完后，`v0.1.0` Release 里会挂好 `QuotaPeek.dmg`。

> **注**：GitHub macOS runner 需具备 Swift 6.2+（Package.swift 要求）。workflow 用 `maxim-lobanov/setup-xcode@v1` 选 `latest-stable`；若 runner 的 Xcode 尚未到 26，请把 `xcode-version` 固定到含 Swift 6.2 的具体版本。
