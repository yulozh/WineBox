import SwiftUI

/// 侧边栏文件树：支持目录展开、文件选择，以及右键重命名/删除/预览/运行。
struct FileTreeView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var renameTarget: FileNode?
    @State private var newName: String = ""
    @State private var deleteTarget: FileNode?
    @State private var previewURL: IdentifiableURL?
    @State private var runOutcome: ScriptRunOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部
            HStack {
                Image(systemName: "folder")
                Text(store.activeProject?.name ?? "项目")
                    .font(.headline)
                Spacer()
                Button { store.refreshFileTree() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Divider()

            if store.fileTree.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus").font(.largeTitle).foregroundColor(.secondary)
                    Text("新建或导入一个项目").font(.footnote).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.fileTree, children: \.children, rowContent: row)
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: 280)
        .glass(cornerRadius: 0)
        .alert("重命名", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("新名称", text: $newName)
            Button("确定") {
                if let target = renameTarget { _ = store.renameFile(at: target.url, to: newName) }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "删除「\(deleteTarget?.name ?? "")」？",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget { store.deleteFile(at: target.url) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("此操作不可撤销")
        }
        .sheet(item: $previewURL) { item in
            NavigationStack {
                WebPreviewView(url: item.url)
                    .navigationTitle(item.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { previewURL = nil } } }
            }
        }
        .sheet(item: $runOutcome) { outcome in
            NavigationStack {
                ScriptRunSheet(outcome: outcome)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { runOutcome = nil } } }
            }
        }
    }

    @ViewBuilder
    private func row(_ node: FileNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder" : icon(for: node.name))
                .foregroundColor(node.isDirectory ? .accentColor : .secondary)
            Text(node.name)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !node.isDirectory else { return }
            store.selectedFileURL = node.url
        }
        .contextMenu {
            if !node.isDirectory {
                Button { store.selectedFileURL = node.url } label: { Label("打开", systemImage: "doc.text") }
                Button { previewURL = IdentifiableURL(url: node.url) } label: { Label("预览", systemImage: "safari") }
                if node.name.lowercased().hasSuffix(".js") {
                    Button {
                        runOutcome = ScriptRunOutcome(file: node.name, result: JSScriptRunner.runFile(at: node.url))
                    } label: { Label("运行脚本", systemImage: "play") }
                }
            }
            Button { renameTarget = node; newName = node.name } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) { deleteTarget = node } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func icon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "php", "js", "ts", "html", "css", "json": return "curlybraces"
        case "md", "txt": return "doc.text"
        default: return "doc"
        }
    }
}

/// 脚本执行结果包装（为 sheet(item:) 提供 Identifiable）。
struct ScriptRunOutcome: Identifiable {
    let id = UUID()
    let file: String
    let result: JSScriptRunner.Result
}

/// 脚本执行结果面板：输出、返回值、异常分段展示。
private struct ScriptRunSheet: View {
    let outcome: ScriptRunOutcome

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !outcome.result.output.isEmpty {
                    block(title: "输出", text: outcome.result.output, color: .primary)
                }
                if !outcome.result.returnValue.isEmpty, outcome.result.returnValue != "undefined" {
                    block(title: "返回值", text: outcome.result.returnValue, color: .primary)
                }
                if let error = outcome.result.error {
                    block(title: "错误", text: error, color: .red)
                }
                if outcome.result.output.isEmpty,
                   outcome.result.returnValue == "undefined" || outcome.result.returnValue.isEmpty,
                   outcome.result.error == nil {
                    Text("脚本执行完成，无输出")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(outcome.file)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func block(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}