import SwiftUI

@main
struct YuixServerApp: App {
    // 全局应用状态：项目、文件树、服务、AI 与 Git 配置。
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
            // 跟随系统深色/浅色模式，毛玻璃材质会自动适配。
        }
    }
}