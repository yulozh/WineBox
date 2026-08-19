import SwiftUI

/// 主界面：工具栏 →（文件树 | 编辑器/终端 | AI 面板）→ 底部服务状态栏。
/// iPhone（compact）上文件树与 AI 面板改为浮层，避免 270/320pt 固定宽度挤爆竖屏。
struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showSettings = false
    @State private var showNewProject = false
    @State private var sidebarVisible = true
    @State private var aiVisible = true
    @State private var activeTab: EditorTab = .editor
    @State private var didApplyCompactDefaults = false

    enum EditorTab: Hashable { case editor, terminal }

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        ZStack {
            GlassGradientBackground()

            VStack(spacing: 12) {
                toolbar
                HStack(spacing: 12) {
                    if sidebarVisible && !isCompact {
                        FileTreeView()
                            .frame(width: 270)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    centerArea
                        .frame(maxWidth: .infinity)
                    if aiVisible && !isCompact {
                        AIPanelView()
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                ServiceStatusBar()
            }
            .padding(12)

            // iPhone 竖屏：侧栏 / AI 以浮层呈现，点暗区收起
            if isCompact && sidebarVisible {
                compactPanel(edge: .leading) {
                    FileTreeView()
                } dismiss: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { sidebarVisible = false }
                }
            }
            if isCompact && aiVisible {
                compactPanel(edge: .trailing) {
                    AIPanelView()
                } dismiss: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { aiVisible = false }
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: sidebarVisible)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: aiVisible)
        .sheet(isPresented: $showNewProject) { NewProjectSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            guard !didApplyCompactDefaults else { return }
            didApplyCompactDefaults = true
            if isCompact {
                sidebarVisible = false
                aiVisible = false
            }
        }
        // 切项目时清掉选中的文件，避免编辑器还开着旧项目的文件
        .onChange(of: store.activeProject) { _ in
            store.selectedFileURL = nil
            store.refreshFileTree()
        }
    }

    /// compact 浮层面板：半透明遮罩 + 侧滑面板
    private func compactPanel<Content: View>(edge: Edge,
                                             @ViewBuilder content: () -> Content,
                                             dismiss: @escaping () -> Void) -> some View {
        ZStack(alignment: edge == .leading ? .leading : .trailing) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            content()
                .frame(width: 300)
                .transition(.move(edge: edge))
        }
    }

    // MARK: - 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            if !isCompact {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    Text("YuixServer")
                        .font(.title2.bold())
                }
            }

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
                    Text("暂无项目")
                }
                Divider()
                Button { showNewProject = true } label: { Label("新建项目", systemImage: "plus") }
                if let active = store.activeProject {
                    Button(role: .destructive) {
                        store.deleteProject(active)
                    } label: {
                        Label("删除「\(active.name)」", systemImage: "trash")
                    }
                }
            } label: {
                Label(store.activeProject?.name ?? "选择项目", systemImage: "folder")
                    .lineLimit(1)
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
            .labelStyle(isCompact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
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
        store.setActive(project)
        store.selectedFileURL = nil
        store.refreshFileTree()
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
            EditorPane(url: url)
                .id(url)   // 换文件时强制重建，重新从磁盘读入
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
}

/// 编辑器面板：进入时读一次文件到本地状态，编辑期间防抖写盘。
/// 旧实现把「读盘」绑在 SwiftUI 的 getter 上、每敲一个字就整树刷新 + 全量重读，
/// 既卡又可能在渲染竞态下覆盖内容；这里改为单一事实源 + 0.4s 防抖落盘。
private struct EditorPane: View {
    @EnvironmentObject var store: ProjectStore
    let url: URL

    @State private var text = ""
    @State private var saveTask: Task<Void, Never>?

    private var language: Language {
        switch (url.lastPathComponent as NSString).pathExtension.lowercased() {
        case "py": return .python
        case "php": return .php
        case "js", "ts", "jsx", "tsx", "json": return .node
        case "html", "htm", "css": return .html
        default: return store.activeProject?.language ?? .html
        }
    }

    var body: some View {
        CodeEditorView(text: $text, language: language)
            .onAppear {
                text = store.readFile(at: url) ?? ""
            }
            .onDisappear {
                saveTask?.cancel()
                _ = store.writeFile(at: url, content: text)   // 离开时兜底保存
            }
            .onChange(of: text) { newValue in
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    _ = store.writeFile(at: url, content: newValue)
                }
            }
    }
}

/// 新建项目表单（带校验反馈，不再静默失败）
struct NewProjectSheet: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "myapp"
    @State private var language: Language = .python
    @State private var errorText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("项目信息") {
                    TextField("项目名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("语言", selection: $language) {
                        ForEach(Language.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Label("端口自动分配", systemImage: "network")
                        .foregroundColor(.secondary)
                }
                Section {
                    Button("创建") {
                        if store.createProject(name: name, language: language) != nil {
                            dismiss()
                        } else {
                            errorText = store.lastCreateError ?? "创建失败"
                        }
                    }
                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("新建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
