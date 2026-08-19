import SwiftUI

/// AI Agent 面板：自然语言 -> 生成代码/解释/调试建议，并可一键把代码写入当前项目目录。
struct AIPanelView: View {
    @EnvironmentObject var store: ProjectStore

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var loading = false
    @State private var statusText = ""

    private let ai = AIService()

    /// 系统提示：约束 AI 输出「代码块 + 简短解释」，方便自动抽取并写入文件。
    private static let systemPrompt =
        "You are a coding assistant inside YuixServer. When writing code, always wrap it in a triple-backtick fenced block with a language tag. Keep explanations short."

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sparkles")
                Text("AI 助手").font(.headline)
                Spacer()
                if !store.aiAPIKey.isEmpty {
                    Text(store.aiConfig.model).font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { msg in
                            bubble(msg)
                                .id(msg.id)
                        }
                        if loading {
                            HStack { ProgressView(); Text("思考中…").font(.caption).foregroundColor(.secondary) }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()

            VStack(spacing: 8) {
                if !statusText.isEmpty {
                    Text(statusText).font(.caption2).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    TextField("描述需求，如「写一个 Express 服务器」", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button(action: send) { Image(systemName: "paperplane.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                }
            }
            .padding(12)
        }
        .glass(cornerRadius: 0)
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(msg.role == .user ? "你" : "AI")
                .font(.caption2).bold()
                .foregroundColor(msg.role == .user ? .accentColor : .secondary)
            Text(msg.content)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(msg.role == .user ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10))

            // 若回复中包含代码块，提供「写入项目」按钮
            if msg.role == .assistant {
                let code = ai.extractCodeBlock(msg.content).code
                if code != msg.content {
                    Button {
                        apply(code: code)
                    } label: {
                        Label("将代码写入项目", systemImage: "square.and.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        messages.append(ChatMessage(role: .user, content: text, timestamp: Date()))
        loading = true
        statusText = ""

        var ctx: [ChatMessage] = [ChatMessage(role: .system, content: Self.systemPrompt, timestamp: Date())]
        ctx += messages

        Task {
            do {
                let reply = try await ai.chat(messages: ctx, config: store.aiConfig, apiKey: store.aiAPIKey)
                messages.append(ChatMessage(role: .assistant, content: reply, timestamp: Date()))
            } catch {
                statusText = "错误：\(error.localizedDescription)"
            }
            loading = false
        }
    }

    /// 把抽取出的代码写入（或追加到）当前项目入口文件
    private func apply(code: String) {
        guard let project = store.activeProject else {
            statusText = "请先新建/选择一个项目"
            return
        }
        let entry = project.language.entryFileName
        let url = store.projectURL(project).appendingPathComponent(entry)
        if let existing = store.readFile(at: url), !existing.isEmpty {
            _ = store.writeFile(at: url, content: existing + "\n" + code + "\n")
        } else {
            _ = store.createFile(named: entry, content: code + "\n")
        }
        statusText = "已写入 \(entry)"
        store.refreshFileTree()
    }
}