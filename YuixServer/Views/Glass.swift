import SwiftUI

/// 毛玻璃（Glassmorphism）视觉：ultraThinMaterial 背景 + 描边 + 柔和阴影，
/// 自动适配深色/浅色模式，符合 Apple HIG 的半透明材质规范。
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 6)
    }
}

extension View {
    /// 给任意视图套上毛玻璃面板
    func glass(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}

/// 主界面的渐变背景：让半透明毛玻璃的「透模糊」效果更明显。
struct GlassGradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.35, green: 0.20, blue: 0.75),
                     Color(red: 0.13, green: 0.38, blue: 0.83),
                     Color(red: 0.10, green: 0.62, blue: 0.72)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}