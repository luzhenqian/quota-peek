import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("CLI 路径（留空自动检测）") {
                pathField("Codex", text: $model.preferences.codexExecutable, placeholder: "/opt/homebrew/bin/codex")
                pathField("Claude", text: $model.preferences.claudeExecutable, placeholder: "/opt/homebrew/bin/claude")
                pathField("Kimi", text: $model.preferences.kimiExecutable, placeholder: "~/.local/bin/kimi")
            }

            AccountListSection(model: model, provider: .codex)
            AccountListSection(model: model, provider: .claude)
            AccountListSection(model: model, provider: .kimi)
            AccountListSection(model: model, provider: .glm)
            AccountListSection(model: model, provider: .grok)

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
