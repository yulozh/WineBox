import Foundation
import AuthenticationServices

/// GitHub OAuth 登录脚手架。
///
/// 说明：完整的 OAuth 授权码流程需要 client_secret，为安全起见它**不应**封装进客户端。
/// 生产环境建议用「个人访问令牌（Fine-grained PAT）」方式（SettingsView 里提供输入框），
/// 本类提供的 ASWebAuthenticationSession 流程需要：
///   1. 在 GitHub 创建 OAuth App，Callback URL 设为 `yuixserver://oauth/callback`；
///   2. 在 Info.plist 注册 URL Scheme `yuixserver`；
///   3. 将 code 交给你的后端换取 token（避免在客户端暴露 secret）。
final class GitHubAuthService: NSObject {

    private var completion: ((Result<String, Error>) -> Void)?

    /// 发起授权（返回授权码 code，供后端换 token）。
    func start(clientID: String, redirectURI: String = "yuixserver://oauth/callback",
               scopes: [String] = ["repo"], completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        var comps = URLComponents(string: "https://github.com/login/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]
        guard let url = comps.url else {
            completion(.failure(NSError(domain: "GitHubAuth", code: -1)))
            return
        }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "yuixserver") { [weak self] callbackURL, error in
            guard let self else { return }
            if let error {
                self.completion?(.failure(error)); return
            }
            guard let callbackURL,
                  let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                self.completion?(.failure(NSError(domain: "GitHubAuth", code: -2))); return
            }
            self.completion?(.success(code))
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }
}

extension GitHubAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return key
        }
        if let first = scenes.first?.windows.first {
            return first
        }
        return UIWindow(frame: UIScreen.main.bounds)
        #else
        return ASPresentationAnchor()
        #endif
    }
}