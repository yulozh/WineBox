import SwiftUI

/// 底部服务状态栏：显示本机 IP、服务列表（名称/端口/状态），
/// 提供 运行/停止 与「预览」，以及项目导入/导出。
struct ServiceStatusBar: View {
    @EnvironmentObject var store: ProjectStore
    @State private var previewURL: IdentifiableURL?
    @State private var showExportPicker = false
    @State private var showImportPicker = false
    @State private var exportFileURL: URL?
    @State private var errorMessage: String?

    private var runtime: RuntimeProviding { DefaultRuntime(root: store.rootURL) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机 IP").font(.caption2).foregroundColor(.secondary)
                    Text(store.localIP)
                        .font(.caption.monospaced())
                }

                Divider().frame(height: 26)

                ForEach(store.services) { service in
                    serviceBadge(service)
                }

                if store.services.isEmpty {
                    Text("暂无服务，请先新建项目").font(.caption).foregroundColor(.secondary)
                }

                Divider().frame(height: 26)

                Button { showImportPicker = true } label: { Label("导入", systemImage: "square.and.arrow.down") }
                Button { beginExport() } label: { Label("导出容器", systemImage: "square.and.arrow.up") }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
        }
        .glass(cornerRadius: 16)
        .sheet(item: $previewURL) { item in
            NavigationStack {
                WebPreviewView(url: item.url)
                    .navigationTitle(item.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { previewURL = nil } } }
            }
        }
        .sheet(isPresented: $showExportPicker) {
            if let url = exportFileURL { ExportDocumentPicker(url: url) }
        }
        .sheet(isPresented: $showImportPicker) {
            ImportDocumentPicker { url in
                showImportPicker = false
                importArchive(url: url)
            }
        }
        // 修复：导出/导入失败原来只 print，用户毫无感知
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func serviceBadge(_ service: ServiceInfo) -> some View {
        // 找不到所属项目时只展示只读信息（旧版会凭空造一个新 UUID 的假项目，状态永远对不上）
        let project = store.projects.first { $0.id == service.projectID }

        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor(service.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).font(.caption.bold()).lineLimit(1)
                Text(":\(service.port) · \(service.language.rawValue)")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if let project {
                Button {
                    runOrStop(service, project: project)
                } label: {
                    Image(systemName: service.status == .running ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)

                Button {
                    if let url = runtime.previewURL(project: project) {
                        previewURL = IdentifiableURL(url: url)
                    }
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .disabled(runtime.previewURL(project: project) == nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func runOrStop(_ service: ServiceInfo, project: Project) {
        if service.status == .running {
            store.stopService(project)
            runtime.stop(project: project)
        } else {
            store.startService(project)
            runtime.start(project: project) { result in
                switch result {
                case .success: store.markServiceRunning(project)
                case .failure: store.markServiceError(project)
                }
            }
        }
    }

    private func beginExport() {
        guard let project = store.activeProject else {
            errorMessage = "请先选择一个项目"
            return
        }
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let tmp = docs.appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            exportFileURL = try ArchiveService.exportProject(project, root: store.rootURL, to: tmp)
            showExportPicker = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importArchive(url: URL) {
        do {
            let dir = try ArchiveService.importArchive(at: url, root: store.rootURL)
            let language = ArchiveService.detectLanguage(in: dir)
            guard store.createProject(name: dir.lastPathComponent, language: language) != nil else {
                errorMessage = store.lastCreateError ?? "导入失败"
                return
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func statusColor(_ status: ServiceStatus) -> Color {
        switch status {
        case .running: return .green
        case .starting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}
