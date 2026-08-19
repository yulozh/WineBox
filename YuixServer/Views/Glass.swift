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

/// 主界面背景：改用系统中性底色（自动适配深/浅色），不再使用彩色渐变。
struct GlassGradientBackground: View {
    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
}