import Foundation

/// 让 `URL` 可用作 SwiftUI `.sheet(item:)` / `.alert(item:)` 的 item 绑定。
/// `URL` 本身不遵守 `Identifiable`，这里用轻量包装提供稳定的 `id`。
struct IdentifiableURL: Identifiable {
    let id: UUID
    let url: URL

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}