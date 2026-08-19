import SwiftUI

/// 设置：AI 服务商/模型/API Key、GitHub 登录（令牌或 OAuth）、网络信息。
/// 敏感信息只写入 Keychain，不落盘明文。
struct SettingsView: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput = ""
    @State private var gitTokenInput = ""
    @State private var oauthClientID = ""
    @State private var saveMessage = ""
    private let auth = GitHubAuthService()

    var body: some View {
        NavigationStack {
            Form {
                Section("AI 编程助手") {
                    TextField("服务商名称（如 OpenAI / DeepSeek）", text: $store.aiConfig.providerName)
                    TextField("Base URL", text: $store.aiConfig.baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("模型", text: $store.aiConfig.model)
                    SecureField("API Key（存钥匙串）", text: $apiKeyInput)
                    Button("保存 AI 配置") {
                        if !apiKeyInput.isEmpty {
                            KeychainStore.save(apiKeyInput, forKey: "ai.apiKey")
                            store.aiAPIKey = apiKeyInput
                            apiKeyInput = ""
                        }
                        saveMessage = "AI 配置已保存"
                    }
                }

                Section("GitHub 集成") {
                    TextField("默认组织/用户名", text: $store.gitConfig.defaultOwner)
                    SecureField("Personal Access Token（存钥匙串）", text: $gitTokenInput)
                    Button("保存 Token") {
                        if !gitTokenInput.isEmpty {
                            KeychainStore.save(gitTokenInput, forKey: "github.token")
                            store.gitToken = gitTokenInput
                            gitTokenInput = ""
                        }
                        saveMessage = "GitHub Token 已保存"
                    }
                    TextField("OAuth Client ID（可选）", text: $oauthClientID)
                    Button("通过 GitHub OAuth 登录") {
                        guard !oauthClientID.isEmpty else { return }
                        auth.start(clientID: oauthClientID) { result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success:
                                    // 生产环境：将授权码交给你的后端换取 token（避免在客户端暴露 secret）
                                    saveMessage = "已获取授权码，请交由后端换 token"
                                case .failure(let err):
                                    saveMessage = "OAuth 失败: \(err.localizedDescription)"
                                }
                            }
                        }
                    }
                }

                Section("网络安全（只读）") {
                    LabeledContent("本机局域网 IP", value: store.localIP)
                    LabeledContent("默认端口范围", value: "\(store.defaultPortRange.lowerBound)-\(store.defaultPortRange.upperBound)")
                }

                if !saveMessage.isEmpty {
                    Section { Text(saveMessage).foregroundColor(.secondary) }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            // 配置改动即时落盘（修复：baseURL/模型/命名空间重启即丢）
            .onChange(of: store.aiConfig) { _ in store.persistConfigs() }
            .onChange(of: store.gitConfig) { _ in store.persistConfigs() }
        }
    }
}