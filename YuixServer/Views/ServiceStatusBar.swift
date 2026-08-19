import SwiftUI

/// 底部服务状态栏：本机 IP、服务列表（真实端口监听状态）、预览、导入导出与端口测试。
struct ServiceStatusBar: View {
    @EnvironmentObject var store: ProjectStore
    @State private var previewURL: IdentifiableURL?
    @State private var showExportPicker = false
    @State private var showImportPicker = false
    @State private var exportFileURL: URL?
    @State private var showPortTest = false
    @State private var errorMessage: String?

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

                Button { showPortTest = true } label: { Label("端口测试", systemImage: "dot.scope") }
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
                    .navigationTitle(item.url.absoluteString)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { previewURL = nil } } }
            }
        }
        .sheet(isPresented: $showPortTest) { PortTestView() }
        .sheet(isPresented: $showExportPicker) {
            if let url = exportFileURL { ExportDocumentPicker(url: url) }
        }
        .sheet(isPresented: $showImportPicker) {
            ImportDocumentPicker { url in
                showImportPicker = false
                importArchive(url: url)
            }
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func serviceBadge(_ service: ServiceInfo) -> some View {
        let project = store.projects.first { $0.id == service.projectID }

        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor(service.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).font(.caption.bold()).lineLimit(1)
                // 服务运行中：直接给出局域网地址，方便其他设备访问测试
                if let project, let url = store.lanURL(for: project) {
                    Text(url.absoluteString)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(":\(service.port) · \(service.language.rawValue)")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            if let project {
                Button {
                    runOrStop(service, project: project)
                } label: {
                    Image(systemName: service.status == .running ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)

                Button {
                    if let url = store.previewURL(for: project) {
                        previewURL = IdentifiableURL(url: url)
                    }
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .disabled(store.previewURL(for: project) == nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func runOrStop(_ service: ServiceInfo, project: Project) {
        if service.status == .running {
            store.stopService(project)
        } else {
            store.startService(project)
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
