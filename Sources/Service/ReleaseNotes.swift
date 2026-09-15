import Foundation

/// 저장소 README 를 **GitHub 가 렌더한 HTML 그대로** 가져온다.
///
/// 마크다운을 우리가 파싱하지 않는 이유:
///  - `AttributedString(markdown:)` 은 표·이미지·코드블록·배지를 못 그린다. README 는 그게 전부다.
///  - 직접 파서를 넣으면 GitHub 방언(alerts, 체크박스, 앵커)까지 따라가야 한다.
/// GitHub 가 `Accept: application/vnd.github.html` 로 완성된 조각을 주므로 그걸 쓴다.
enum ReleaseNotes {
    static let repo = "FlameLaunchers/FlameLauncher"

    private static var endpoint: URL {
        URL(string: "https://api.github.com/repos/\(repo)/readme")!
    }

    /// 마지막으로 받아둔 HTML. 네트워크가 없을 때 이걸 보여준다.
    private static let cacheFile = Paths.caches.appending(path: "release_notes.html")

    /// - Returns: GitHub 가 렌더한 HTML 조각(`<article class="markdown-body">…`).
    static func fetch() async -> String? {
        // ⚠️ 인증 없는 GitHub API 는 IP 당 시간당 60회다. 화면을 열 때마다 때리면 금방 막힌다 —
        //    받은 건 반드시 캐시하고, 실패하면 캐시로 돌아간다.
        let headers = [
            "Accept": "application/vnd.github.html",
            "User-Agent": "FlameLauncher-iOS",
        ]
        if let data = try? await HTTP.data(endpoint, headers: headers),
           let html = String(data: data, encoding: .utf8), !html.isEmpty {
            try? data.write(to: cacheFile, options: .atomic)
            return html
        }
        guard let cached = try? Data(contentsOf: cacheFile) else { return nil }
        return String(data: cached, encoding: .utf8)
    }

    /// GitHub 다크 테마를 우리 팔레트로 옮긴 CSS 로 감싼다.
    ///
    /// ⚠️ 조각만 WKWebView 에 넣으면 기본 흰 배경에 세리프 폰트로 나온다 —
    ///    문서 껍데기와 스타일을 직접 씌워야 GitHub 처럼 보인다.
    static func page(wrapping fragment: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: dark; }
        body {
          margin: 0; padding: 20px 22px 40px;
          background: #05080F; color: #E8F2FF;
          font: 14px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          -webkit-text-size-adjust: 100%;
        }
        .markdown-body { max-width: 900px; margin: 0 auto; }
        h1, h2, h3, h4 { color: #E8F2FF; font-weight: 700; line-height: 1.3; margin: 1.6em 0 .6em; }
        h1 { font-size: 1.7em; } h2 { font-size: 1.35em; } h3 { font-size: 1.12em; }
        h1, h2 { border-bottom: 1px solid #1C2E47; padding-bottom: .3em; }
        a { color: #2E9BFF; text-decoration: none; }
        a:hover { text-decoration: underline; }
        p, li { color: #C6D6EC; }
        strong { color: #E8F2FF; }
        code {
          background: #0B1422; color: #7CC9FF; padding: .16em .4em;
          border-radius: 5px; font-size: .88em;
          font-family: ui-monospace, "SF Mono", Menlo, monospace;
        }
        pre {
          background: #0B1422; border: 1px solid #1C2E47; border-radius: 10px;
          padding: 13px 15px; overflow-x: auto;
        }
        pre code { background: none; color: #C6D6EC; padding: 0; }
        blockquote {
          margin: 1em 0; padding: .2em 0 .2em 14px;
          border-left: 3px solid #2E9BFF; color: #8CA2C0;
        }
        table { border-collapse: collapse; width: 100%; margin: 1em 0; display: block; overflow-x: auto; }
        th, td { border: 1px solid #1C2E47; padding: 7px 11px; text-align: left; }
        th { background: #0B1422; color: #E8F2FF; }
        img { max-width: 100%; height: auto; }
        hr { border: 0; border-top: 1px solid #1C2E47; margin: 1.8em 0; }
        ul, ol { padding-left: 1.35em; }
        /* GitHub 의 앵커 링크(제목 옆 🔗)는 터치 환경에서 쓸모가 없다 */
        .anchor, .octicon-link { display: none !important; }
        </style></head><body>\(fragment)</body></html>
        """
    }
}
