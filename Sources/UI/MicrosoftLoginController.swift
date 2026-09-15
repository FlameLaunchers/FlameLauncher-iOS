import UIKit
import WebKit

/// Microsoft 로그인 창. 리디렉션을 직접 가로채서 인증 코드를 뽑는다.
///
/// ⚠️ `ASWebAuthenticationSession` 을 쓸 수 없다. 그건 **커스텀 스킴만** 가로채는데,
///    이 client_id 의 리디렉션 대상은 `https://login.live.com/oauth20_desktop.srf` 라
///    로그인을 마치면 그 https 페이지("일반적으로 표시되지 않는 페이지로 이동했습니다")에
///    그대로 멈춰버린다 — 완료 핸들러가 영영 불리지 않는다.
///
///    그래서 안드로이드판과 같은 방식으로 돌아간다: WKWebView 를 직접 띄우고
///    `decidePolicyFor` 에서 리디렉션 URL 을 가로채 `?code=` 를 읽는다.
@MainActor
final class MicrosoftLoginController: UIViewController, WKNavigationDelegate {
    private let authURL: URL
    private let redirectPrefix: String
    private let completion: (Result<String, Error>) -> Void

    private var webView: WKWebView!
    private var finished = false

    init(authURL: URL, redirectPrefix: String,
         completion: @escaping (Result<String, Error>) -> Void) {
        self.authURL = authURL
        self.redirectPrefix = redirectPrefix
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        // 쿠키를 남기지 않는다 — 계정 전환이 자연스럽고 남의 기기에 로그인이 안 남는다.
        config.websiteDataStore = .nonPersistent()

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let cancel = UIButton(type: .system)
        cancel.setTitle("취소", for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)
        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])

        webView.load(URLRequest(url: authURL))
    }

    /// 사용자가 시트를 아래로 내려 닫은 경우도 취소로 친다.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        finish(.failure(AuthStore.AuthError.cancelled))
    }

    @objc private func cancelTapped() {
        finish(.failure(AuthStore.AuthError.cancelled))
        dismiss(animated: true)
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        completion(result)
    }

    /// 리디렉션 URL 에서 결과를 읽는다. 화면 없이 테스트할 수 있도록 순수 함수로 뺐다.
    nonisolated static func parse(redirect url: URL) -> Result<String, Error> {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let code = value("code"), !code.isEmpty {
            return .success(code)
        }
        if value("error")?.hasPrefix("access_denied") == true {
            // 사용자가 동의 화면에서 거절 — 취소와 같게 취급한다.
            return .failure(AuthStore.AuthError.cancelled)
        }
        return .failure(AuthStore.AuthError.authorize(
            value("error_description") ?? value("error") ?? "인증 코드를 받지 못했습니다"))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              url.absoluteString.hasPrefix(redirectPrefix)
        else {
            decisionHandler(.allow)
            return
        }

        // 리디렉션 도착 — 여기서 멈추고 결과를 읽는다. 실제로 페이지를 열 필요는 없다.
        decisionHandler(.cancel)

        finish(Self.parse(redirect: url))
        dismiss(animated: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 우리가 취소시킨 리디렉션은 오류가 아니다.
        guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }
        finish(.failure(error))
        dismiss(animated: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }
        finish(.failure(error))
        dismiss(animated: true)
    }
}
