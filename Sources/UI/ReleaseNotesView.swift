import SwiftUI
import WebKit

/// 메인 화면 오른쪽 5/6 을 채우는 업데이트 노트.
/// 저장소 README 를 GitHub 가 렌더한 HTML 그대로 보여준다.
struct ReleaseNotesView: View {
    @State private var html: String?
    @State private var failed = false

    var body: some View {
        ZStack {
            FlameColor.bgDark

            if let html {
                MarkdownWebView(html: ReleaseNotes.page(wrapping: html))
            } else if failed {
                placeholder("📡", String(localized: "업데이트 노트를 불러오지 못했어요"),
                            String(localized: "네트워크를 확인하고 다시 시도해 주세요.")) {
                    Button("다시 시도") { Task { await load() } }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(FlameColor.primary)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .flameCard(fill: FlameColor.bgItem, radius: 9)
                        .flameTappable()
                }
            } else {
                ProgressView().tint(FlameColor.primary)
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func placeholder<A: View>(_ emoji: String, _ title: String, _ detail: String,
                                      @ViewBuilder action: () -> A) -> some View {
        VStack(spacing: 10) {
            Text(emoji).font(.system(size: 36))
            Text(title).font(.system(size: 14, weight: .bold))
                .foregroundStyle(FlameColor.textMain)
            Text(detail).font(.system(size: 11))
                .foregroundStyle(FlameColor.textSub)
                .multilineTextAlignment(.center)
            action()
        }
        .padding(28)
    }

    private func load() async {
        failed = false
        let fetched = await ReleaseNotes.fetch()
        if let fetched { html = fetched } else { failed = true }
    }
}

/// ⚠️ 마크다운을 SwiftUI 로 그리지 않고 WebView 를 쓰는 이유는 ReleaseNotes 주석 참고.
private struct MarkdownWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = UIColor(FlameColor.bgDark)
        view.scrollView.indicatorStyle = .white
        // ⚠️ README 의 링크를 눌러 웹뷰 안에서 이동해 버리면 런처가 브라우저가 된다.
        //    바깥 링크는 사파리로 넘긴다(navigationDelegate).
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        // baseURL 을 GitHub 로 둬야 README 안의 상대경로 이미지·링크가 풀린다.
        view.loadHTMLString(html, baseURL: URL(string: "https://github.com/\(ReleaseNotes.repo)/raw/main/"))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async
                     -> WKNavigationActionPolicy {
            // 최초 loadHTMLString 은 통과시키고, 사용자가 누른 링크만 밖으로 보낸다.
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else { return .allow }
            await UIApplication.shared.open(url)
            return .cancel
        }
    }
}
