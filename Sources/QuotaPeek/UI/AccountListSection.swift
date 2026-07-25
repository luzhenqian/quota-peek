import SwiftUI

/// Renders all configured accounts for one provider and exposes the account-scoped
/// controls used by the settings window.
struct AccountListSection: View {
    @ObservedObject var model: AppModel
    let provider: ProviderID
    @State private var showingAddSheet = false

    private var accounts: [ProviderAccount] {
        model.preferences.accounts.filter { $0.provider == provider }
    }

    var body: some View {
        Section(provider.displayName) {
            ForEach(accounts) { account in
                AccountRow(model: model, account: account)
            }

            Button("+ 添加账号") {
                showingAddSheet = true
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddAccountSheet(
                model: model,
                provider: provider,
                isPresented: $showingAddSheet
            )
        }
    }
}

private struct AccountRow: View {
    @ObservedObject var model: AppModel
    let account: ProviderAccount
    @State private var label: String
    @State private var showingDeleteConfirmation = false
    @FocusState private var isEditingLabel: Bool

    init(model: AppModel, account: ProviderAccount) {
        self.model = model
        self.account = account
        _label = State(initialValue: account.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("账号名", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .focused($isEditingLabel)
                    .onSubmit {
                        commitLabel()
                    }
                    .onChange(of: isEditingLabel) { _, isFocused in
                        if !isFocused {
                            commitLabel()
                        }
                    }
                    .onChange(of: account.label) { _, newLabel in
                        if !isEditingLabel {
                            label = newLabel
                        }
                    }

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .accessibilityLabel("启用账号 \(account.label)")

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("删除账号")
                .accessibilityLabel("删除账号 \(account.label)")
            }

            CredentialEditor(model: model, account: account)
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "删除账号“\(account.label)”？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除账号", role: .destructive) {
                model.removeAccount(id: account.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会同时删除 QuotaPeek 为该账号保存的凭证和专用登录目录，且无法撤销。")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: {
                model.preferences.accounts
                    .first(where: { $0.id == account.id })?
                    .enabled ?? false
            },
            set: { newValue in
                guard let index = model.preferences.accounts.firstIndex(where: {
                    $0.id == account.id
                }) else {
                    return
                }
                // Assigning a copied value back is intentional: mutating an element
                // through the published property can bypass AppModel.preferences.didSet.
                var updated = model.preferences
                updated.accounts[index].enabled = newValue
                model.preferences = updated
            }
        )
    }

    private func commitLabel() {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            label = account.label
            return
        }
        label = trimmed
        if trimmed != account.label {
            model.renameAccount(id: account.id, label: trimmed)
        }
    }
}

/// Shows the account-specific credential state and editing controls.
private struct CredentialEditor: View {
    @ObservedObject var model: AppModel
    let account: ProviderAccount
    @State private var secretInput = ""
    @State private var saveStatus: SaveStatus?

    var body: some View {
        switch account.credential {
        case .cliHome:
            Text(cliStatusText)
                .font(.caption)
                .foregroundStyle(cliStatusColor)

        case .kimi:
            HStack {
                Text(kimiStatusText)
                    .font(.caption)
                    .foregroundStyle(runtimeStatusColor)
                Spacer()
                if kimiIsLoggedIn {
                    Button("退出网页登录") {
                        Task {
                            await model.kimiLogout(accountID: account.id)
                        }
                    }
                } else {
                    Button("追加网页登录") {
                        Task {
                            await model.kimiLogin(accountID: account.id)
                        }
                    }
                }
            }

        case .apiKey(let baseURL):
            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL: \(baseURL)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                secretEditor(placeholder: "API Key（保存在 macOS 钥匙串）")
                credentialStatus
            }

        case .cookie:
            VStack(alignment: .leading, spacing: 4) {
                secretEditor(placeholder: "grok.com Cookie（保存在 macOS 钥匙串）")
                credentialStatus
            }
        }
    }

    private var kimiIsLoggedIn: Bool {
        model.kimiWebIsLoggedIn(accountID: account.id)
    }

    private var kimiStatusText: String {
        let mode = kimiIsLoggedIn ? "网页登录" : "使用官方 CLI"
        guard account.enabled else { return "已停用 · \(mode)" }
        return "\(mode) · \(runtimeStatusText)"
    }

    private var cliStatusText: String {
        account.enabled ? runtimeStatusText : "已停用"
    }

    private var cliStatusColor: Color {
        runtimeStatusColor
    }

    private var runtimeStatusText: String {
        snapshotError ?? "正常"
    }

    private var runtimeStatusColor: Color {
        guard account.enabled else { return .secondary }
        return snapshotError == nil ? .green : .orange
    }

    private var snapshotError: String? {
        model.visibleSnapshots
            .first(where: { $0.accountID == account.id })?
            .errorMessage
    }

    private func secretEditor(placeholder: String) -> some View {
        HStack {
            SecureField(placeholder, text: $secretInput)
                .textFieldStyle(.roundedBorder)
            Button("保存") {
                save()
            }
            .disabled(secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var credentialStatus: some View {
        let status = credentialStatusValue
        return Text(status.message)
            .font(.caption)
            .foregroundStyle(status.color)
    }

    private var credentialStatusValue: CredentialStatus {
        if !account.enabled {
            return CredentialStatus(message: "已停用", color: .secondary)
        }
        if let saveStatus, saveStatus.isError {
            return CredentialStatus(message: saveStatus.message, color: .red)
        }
        guard model.hasSecret(for: account) else {
            return CredentialStatus(message: "尚未配置凭证", color: .secondary)
        }
        if let snapshotError {
            return CredentialStatus(message: snapshotError, color: .orange)
        }
        return CredentialStatus(message: "已保存凭证", color: .green)
    }

    private func save() {
        do {
            try model.saveSecret(secretInput, for: account)
            secretInput = ""
            saveStatus = SaveStatus(message: "已保存", isError: false)
        } catch {
            saveStatus = SaveStatus(message: error.localizedDescription, isError: true)
        }
    }
}

private struct AddAccountSheet: View {
    @ObservedObject var model: AppModel
    let provider: ProviderID
    @Binding var isPresented: Bool
    @State private var label = ""
    @State private var baseURL = "https://open.bigmodel.cn"
    @State private var secret = ""
    @State private var errorMessage: String?
    @State private var credentialAccountWasCreated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新增 \(provider.displayName) 账号")
                .font(.headline)

            TextField("账号名，如「工作」", text: $label)
                .textFieldStyle(.roundedBorder)

            if provider == .glm {
                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key（保存在 macOS 钥匙串）", text: $secret)
                    .textFieldStyle(.roundedBorder)
            } else if provider == .grok {
                SecureField("grok.com Cookie（保存在 macOS 钥匙串）", text: $secret)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text("确认后会打开 Terminal，请在里面正常登录一次。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") {
                    isPresented = false
                }
                Button(credentialAccountWasCreated ? "完成" : "添加") {
                    if credentialAccountWasCreated {
                        isPresented = false
                    } else {
                        add()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!credentialAccountWasCreated && !canAdd)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var isCLIProvider: Bool {
        provider == .codex || provider == .claude || provider == .kimi
    }

    private var canAdd: Bool {
        guard !trimmedLabel.isEmpty else { return false }
        if provider == .glm {
            return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if provider == .grok {
            return !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return isCLIProvider
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        errorMessage = nil

        if isCLIProvider {
            do {
                try model.addCLIAccount(provider: provider, label: trimmedLabel)
                dismissAfterSuccess()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        let existingIDs = Set(model.preferences.accounts.map(\.id))
        model.addCredentialAccount(
            provider: provider,
            label: trimmedLabel,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let account = model.preferences.accounts.last(where: {
            !existingIDs.contains($0.id) && $0.provider == provider
        }) else {
            errorMessage = "未能创建账号，请重试。"
            return
        }

        do {
            try model.saveSecret(secret, for: account)
            dismissAfterSuccess()
        } catch {
            // Keep the newly created account visible so the user can retry saving
            // from its row instead of losing the account without an explanation.
            credentialAccountWasCreated = true
            errorMessage = "账号已添加，但凭证保存失败：\(error.localizedDescription)"
        }
    }

    private func dismissAfterSuccess() {
        label = ""
        baseURL = "https://open.bigmodel.cn"
        secret = ""
        errorMessage = nil
        credentialAccountWasCreated = false
        isPresented = false
    }
}

private struct SaveStatus {
    let message: String
    let isError: Bool
}

private struct CredentialStatus {
    let message: String
    let color: Color
}
