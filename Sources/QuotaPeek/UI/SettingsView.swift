import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsSection = .general
    @State private var glmAPIKey = ""
    @State private var keyStatus = ""
    @State private var grokCookie = ""
    @State private var grokStatus = ""

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            Group {
                switch selection {
                case .general:
                    generalSettings
                case .providers:
                    providerSettings
                case .accounts:
                    accountSettings
                case .about:
                    aboutSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var generalSettings: some View {
        settingsForm(title: "通用", subtitle: "管理启动方式、刷新频率与额度提醒。") {
            Section("启动") {
                Toggle(
                    "登录时自动启动",
                    isOn: Binding(
                        get: { model.preferences.launchAtLoginEnabled },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    )
                )
                Toggle("启动时显示悬浮面板", isOn: $model.preferences.floatingPanelEnabled)

                if model.launchAtLoginStatus == .requiresApproval {
                    statusText("需要在“系统设置 → 通用 → 登录项”中允许 QuotaPeek。", color: .orange)
                } else if let error = model.launchAtLoginError {
                    statusText("无法更新登录项：\(error)", color: .red)
                }
            }

            Section("刷新") {
                Picker("自动刷新", selection: $model.preferences.refreshIntervalMinutes) {
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                }
            }

            Section("提醒") {
                Toggle("低额度通知", isOn: $model.preferences.notificationsEnabled)
                Picker("提醒阈值", selection: $model.preferences.notificationThreshold) {
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("25%").tag(25)
                }
                .disabled(!model.preferences.notificationsEnabled)
            }
        }
    }

    private var providerSettings: some View {
        settingsForm(title: "平台", subtitle: "只显示并刷新你实际使用的平台。") {
            Section("监控平台") {
                providerToggle("Codex", detail: "ChatGPT Codex 额度", isOn: $model.preferences.codexEnabled)
                providerToggle("Claude", detail: "Claude Pro / Max 额度", isOn: $model.preferences.claudeEnabled)
                providerToggle("Kimi", detail: "Kimi Coding 与会员额度", isOn: $model.preferences.kimiEnabled)
                providerToggle("GLM Coding Plan", detail: "智谱 Coding Plan 额度", isOn: $model.preferences.glmEnabled)
                providerToggle("Grok", detail: "grok.com 模型请求额度", isOn: $model.preferences.grokEnabled)
            }

            Section {
                Text("关闭的平台不会发起本地 CLI 或网络查询，已有缓存会保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accountSettings: some View {
        settingsForm(title: "账号与凭证", subtitle: "配置本地 CLI 路径和各平台的访问凭证。") {
            Section("CLI 路径（留空自动检测）") {
                pathField("Codex", text: $model.preferences.codexExecutable, placeholder: "/opt/homebrew/bin/codex")
                pathField("Claude", text: $model.preferences.claudeExecutable, placeholder: "/opt/homebrew/bin/claude")
                pathField("Kimi", text: $model.preferences.kimiExecutable, placeholder: "~/.local/bin/kimi")
            }

            Section("Kimi 网页账号") {
                HStack {
                    credentialStatus(
                        model.kimiWebIsLoggedIn() ? "已登录，可读取套餐与月度额度" : "未登录，当前使用官方 CLI",
                        configured: model.kimiWebIsLoggedIn()
                    )
                    Spacer()
                    if model.kimiWebIsLoggedIn() {
                        Button("退出登录") { Task { await model.kimiLogout() } }
                    } else {
                        Button("登录") { Task { await model.kimiLogin() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text("登录状态只保存在本机，token 刷新由 Kimi 网页会话自动完成。")
                    .font(.caption)
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
                credentialStatus(
                    keyStatus.isEmpty ? (model.hasGLMAPIKey() ? "已配置凭证" : "尚未配置凭证") : keyStatus,
                    configured: model.hasGLMAPIKey()
                )
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
                credentialStatus(
                    grokStatus.isEmpty ? (model.hasGrokCookie() ? "已配置凭证" : "尚未配置凭证") : grokStatus,
                    configured: model.hasGrokCookie()
                )
                Text("从浏览器开发者工具中复制 grok.com 请求的完整 Cookie。Cookie 过期后需要重新保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aboutSettings: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("余量")
                .font(.title.bold())

            Text("QuotaPeek \(appVersion)")
                .foregroundStyle(.secondary)

            Text("所有大模型额度，一眼看清。")
                .font(.headline)
                .padding(.top, 4)

            Text("QuotaPeek 只在本机调用官方 CLI 或接口，不会上传账号凭证与额度数据。API Key 和 Cookie 保存在 macOS 钥匙串中。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            Spacer()

            Text("© 2026 QuotaPeek · MIT License")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(44)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "0.1.1"
    }

    private func settingsForm<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
                content()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func providerToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pathField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title).frame(width: 62, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func credentialStatus(_ text: String, configured: Bool) -> some View {
        Label(text, systemImage: configured ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption)
            .foregroundStyle(configured ? .green : .secondary)
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case providers
    case accounts
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .providers: "平台"
        case .accounts: "账号与凭证"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .providers: "square.grid.2x2"
        case .accounts: "key"
        case .about: "info.circle"
        }
    }
}
