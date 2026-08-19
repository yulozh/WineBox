import SwiftUI

/// 底部服务状态栏：显示局域网 IP、活动服务列表（名称/端口/状态），
/// 提供 运行/停止 与「预览/打开地址」，并支持「导出容器」。
struct ServiceStatusBar: View {
    @EnvironmentObject var store: ProjectStore
    @State private var previewURL: URL?
    @State private var showExportPicker = false
    @State private var showImportPicker = false
    @State private var exportFileURL: URL?

    private var runtime: RuntimeProviding { DefaultRuntime(root: store.rootURL) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // 局域网访问提示
                VStack(alignment: .leading, spacing: 2) {
                    Text("局域网 IP").font(.caption2).foregroundColor(.secondary)
                    Text("http://\(store.localIP)")
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
        .sheet(item: $previewURL) { url in
            NavigationStack {
                WebPreviewView(url: url)
                    .navigationTitle(url.lastPathComponent)
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
    }

    private func serviceBadge(_ service: ServiceInfo) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(service.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).font(.caption.bold()).lineLimit(1)
                Text(":\(service.port) · \(service.language.rawValue)")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Button {
                runOrStop(service)
            } label: {
                Image(systemName: service.status == .running ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)

            Button {
                if let url = runtime.previewURL(project: project(for: service)) {
                    previewURL = url
                }
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .disabled(runtime.previewURL(project: project(for: service)) == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func project(for service: ServiceInfo) -> Project {
        store.projects.first { $0.id == service.projectID }
            ?? Project(name: service.name, language: service.language, port: service.port)
    }

    private func runOrStop(_ service: ServiceInfo) {
        let project = project(for: service)
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
        guard let project = store.activeProject else { return }
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let tmp = docs.appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let zip = try ArchiveService.exportProject(project, root: store.rootURL, to: tmp)
            exportFileURL = zip
            showExportPicker = true
        } catch {
            print("导出失败: \(error.localizedDescription)")
        }
    }

    private func importArchive(url: URL) {
        do {
            let dir = try ArchiveService.importArchive(at: url, root: store.rootURL)
            let name = dir.lastPathComponent
            // 导入后建项目元数据（默认 node/端口自动分配）
            _ = store.createProject(name: name, language: .node)
        } catch {
            print("导入失败: \(error.localizedDescription)")
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