import SwiftUI
import WebKit

/// 内置浏览器：用于预览静态页面或「打开服务地址」。
/// 支持本地文件 URL 与 http(s) 远程 URL 两种方式。
struct WebPreviewView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if web.url == nil || web.url != url {
            if url.isFileURL {
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                web.load(URLRequest(url: url))
            }
        }
    }
}