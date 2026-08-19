import SwiftUI

/// 主界面：渐变背景 + 毛玻璃布局。
/// 布局：工具栏 →（侧边栏文件树 | 中心区[编辑器/终端] | AI 面板）→ 底部服务状态栏。
/// 侧边栏与 AI 面板可折叠，适配 iPhone 竖屏与 iPad 分屏。
struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showSettings = false
    @State private var showNewProject = false
    @State private var sidebarVisible = true
    @State private var aiVisible = true
    @State private var activeTab: EditorTab = .editor

    enum EditorTab: Hashable { case editor, terminal }

    var body: some View {
        ZStack {
            GlassGradientBackground()

            VStack(spacing: 12) {
                toolbar
                HStack(spacing: 12) {
                    if sidebarVisible {
                        FileTreeView()
                            .frame(width: 270)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    centerArea
                        .frame(maxWidth: .infinity)
                    if aiVisible {
                        AIPanelView()
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                ServiceStatusBar()
            }
            .padding(12)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: sidebarVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: aiVisible)
        .sheet(isPresented: $showNewProject) { NewProjectSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: store.activeProject) { _ in store.refreshFileTree() }
    }

    // MARK: - 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("YuixServer")
                    .font(.title2.bold())
            }

            // 项目列表：切换/新建/删除
            Menu {
                ForEach(store.projects) { p in
                    Button { selectProject(p) } label: {
                        if store.activeProject?.id == p.id {
                            Label("\(p.name) · :\(p.port)", systemImage: "checkmark")
                        } else {
                            Text("\(p.name) · :\(p.port)")
                        }
                    }
                }
                if store.projects.isEmpty {
                    Text("暂无项目").foregroundColor(.secondary)
                }
                Divider()
                Button { showNewProject = true } label: { Label("新建项目", systemImage: "plus") }
                if store.activeProject != nil {
                    Button(role: .destructive) { deleteActiveProject() } label: {
                        Label("删除当前项目", systemImage: "trash")
                    }
                }
            } label: {
                Label(store.activeProject?.name ?? "选择项目", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button { withAnimation { sidebarVisible.toggle() } } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.bordered)
            .disabled(store.activeProject == nil)

            Spacer()

            Button { showNewProject = true } label: {
                Label("新建", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            Button { withAnimation { aiVisible.toggle() } } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.bordered)

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glass()
    }

    // MARK: - 项目操作

    private func selectProject(_ project: Project) {
        store.activeProject = project
        store.selectedFileURL = nil
        store.refreshFileTree()
    }

    private func deleteActiveProject() {
        if let project = store.activeProject {
            store.deleteProject(project)
        }
    }

    // MARK: - 中心区（编辑器 / 终端）

    private var centerArea: some View {
        VStack(spacing: 0) {
            Picker("", selection: $activeTab) {
                Label("编辑器", systemImage: "chevron.left.forwardslash.chevron.right").tag(EditorTab.editor)
                Label("终端", systemImage: "terminal").tag(EditorTab.terminal)
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider()

            Group {
                switch activeTab {
                case .editor: editorArea
                case .terminal: TerminalView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glass()
    }

    // MARK: - 编辑器

    @ViewBuilder
    private var editorArea: some View {
        if let url = store.selectedFileURL {
            CodeEditorView(text: Binding(
                get: { store.readFile(at: url) ?? "" },
                set: { newValue in _ = store.writeFile(at: url, content: newValue) }
            ), language: languageFor(url))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text("从左侧选择文件开始编辑").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func languageFor(_ url: URL) -> Language {
        switch (url.lastPathComponent as NSString).pathExtension.lowercased() {
        case "py": return .python
        case "php": return .php
        case "js", "ts", "jsx", "tsx", "json": return .node
        case "html", "htm", "css": return .html
        default: return store.activeProject?.language ?? .html
        }
    }
}

/// 新建项目表单
struct NewProjectSheet: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "myapp"
    @State private var language: Language = .python

    var body: some View {
        NavigationStack {
            Form {
                Section("项目信息") {
                    TextField("项目名称", text: $name)
                    Picker("语言", selection: $language) {
                        ForEach(Language.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Label("端口自动分配", systemImage: "network")
                        .foregroundColor(.secondary)
                }
                Section {
                    Button("创建") {
                        _ = store.createProject(name: name, language: language)
                        dismiss()
                    }
                }
            }
            .navigationTitle("新建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}