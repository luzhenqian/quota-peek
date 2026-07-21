import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var glmAPIKey = ""
    @State private var keyStatus = ""
    @State private var grokCookie = ""
    @State private var grokStatus = ""

    var body: some View {
        Form {
            Section("监控平台") {
                Toggle("Codex", isOn: $model.preferences.codexEnabled)
                Toggle("Claude", isOn: $model.preferences.claudeEnabled)
                Toggle("Kimi", isOn: $model.preferences.kimiEnabled)
                Toggle("GLM Coding Plan", isOn: $model.preferences.glmEnabled)
                Toggle("Grok", isOn: $model.preferences.grokEnabled)
            }

            Section("CLI 路径（留空自动检测）") {
                pathField("Codex", text: $model.preferences.codexExecutable, placeholder: "/opt/homebrew/bin/codex")
                pathField("Claude", text: $model.preferences.claudeExecutable, placeholder: "/opt/homebrew/bin/claude")
                pathField("Kimi", text: $model.preferences.kimiExecutable, placeholder: "~/.local/bin/kimi")
            }

            Section("Kimi 网页账号") {
                HStack {
                    Text(model.kimiWebIsLoggedIn() ? "已登录（网页接口，含套餐名与月度额度）"
                                                    : "未登录（使用官方 CLI）")
                        .font(.caption)
                        .foregroundStyle(model.kimiWebIsLoggedIn() ? .green : .secondary)
                    Spacer()
                    if model.kimiWebIsLoggedIn() {
                        Button("退出登录") { Task { await model.kimiLogout() } }
                    } else {
                        Button("登录 Kimi 网页账号") { Task { await model.kimiLogin() } }
                    }
                }
                Text("登录后 Kimi 卡片改用网页会员接口，一次显示每月/每周/5 小时额度与套餐名；登录状态保存在本机，token 刷新由 Kimi 网页会话自动完成。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Grok") {
                HStack {
                    SecureField("grok.com Cookie（保存在 macOS 钥匙串）", text: $grokCookie)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") {
                        do {
                            try model.saveGrokCookie(grokCookie)
                            grokCookie = ""
                            grokStatus = "已保存"
                        } catch {
                            grokStatus = error.localizedDescription
                        }
                    }
                }
                Text(grokStatus.isEmpty ? (model.hasGrokCookie() ? "已保存凭证" : "尚未配置凭证") : grokStatus)
                    .font(.caption)
                    .foregroundStyle(model.hasGrokCookie() ? .green : .secondary)
                Text("Grok 无官方 CLI，内嵌登录会被 xAI 的 Cloudflare 拦。改为：浏览器登录 grok.com → 打开开发者工具（⌥⌘I）→ Network → 刷新 → 点任一 grok.com 请求 → Request Headers → 复制整段 Cookie 值粘贴到此。Cookie 会过期，失效后重新复制即可。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("GLM Coding Plan") {
                TextField("Base URL", text: $model.preferences.glmBaseURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    SecureField("API Key（保存在 macOS 钥匙串）", text: $glmAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") {
                        do {
                            try model.saveGLMAPIKey(glmAPIKey)
                            glmAPIKey = ""
                            keyStatus = "已保存"
                        } catch {
                            keyStatus = error.localizedDescription
                        }
                    }
                }
                Text(keyStatus.isEmpty ? (model.hasGLMAPIKey() ? "已检测到凭证" : "尚未配置凭证") : keyStatus)
                    .font(.caption)
                    .foregroundStyle(model.hasGLMAPIKey() ? .green : .secondary)
            }

            Section("刷新与提醒") {
                Picker("自动刷新", selection: $model.preferences.refreshIntervalMinutes) {
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                }
                Toggle("低额度通知", isOn: $model.preferences.notificationsEnabled)
                Picker("提醒阈值", selection: $model.preferences.notificationThreshold) {
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("25%").tag(25)
                }
                Toggle("启动时显示悬浮面板", isOn: $model.preferences.floatingPanelEnabled)
            }

            Section {
                Text("QuotaPeek 只在本机调用官方 CLI/API；不会上传账号凭证或额度数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pathField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title).frame(width: 62, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
