import Foundation

/// 안드로이드 쪽 OkHttp + Gson 보일러플레이트(파일마다 client/gson 인스턴스 + try/catch)를
/// 대체하는 얇은 래퍼. URLSession + Codable 이면 충분해서 의존성을 하나도 안 쓴다.
enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60 * 60      // 큰 모드팩 다운로드용
        // 에셋은 1~50KB 짜리가 수천 개다 — 대역폭이 아니라 요청 왕복 횟수가 병목이라
        // 동시 연결 수를 올리는 게 그대로 체감 속도가 된다.
        c.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: c)
    }()

    struct StatusError: LocalizedError {
        let code: Int
        let url: String
        /// 실패 응답 본문. Xbox Live 는 거절 사유(XErr)를 여기에만 담아 보내므로 버리면 안 된다.
        var body: Data = Data()

        var errorDescription: String? { "요청 실패 (\(code)): \(url)" }

        /// 본문을 JSON 으로 읽는다. 파싱 실패면 nil.
        var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    static func data(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: req)
        try check(response, url, body: data)
        return data
    }

    static func json<T: Decodable>(
        _ type: T.Type, from url: URL, headers: [String: String] = [:]
    ) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(url, headers: headers))
    }

    static func text(_ url: URL, headers: [String: String] = [:]) async throws -> String {
        String(decoding: try await data(url, headers: headers), as: UTF8.self)
    }

    static func post<T: Decodable>(
        _ type: T.Type,
        url: URL,
        body: Data,
        contentType: String,
        headers: [String: String] = [:]
    ) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: req)
        try check(response, url, body: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func form<T: Decodable>(
        _ type: T.Type, url: URL, fields: [String: String]
    ) async throws -> T {
        let body = Data(formEncoded(fields).utf8)
        return try await post(T.self, url: url, body: body,
                              contentType: "application/x-www-form-urlencoded")
    }

    /// application/x-www-form-urlencoded 본문을 만든다.
    ///
    /// ⚠️ `URLComponents.percentEncodedQuery` 를 쓰면 안 된다. 그건 쿼리 문자열 규칙이라
    ///    `+` 를 그대로 통과시키는데, 폼 본문에서 `+` 는 **공백**을 뜻한다. OAuth 코드나
    ///    갱신 토큰에 `+` 가 하나만 들어 있어도 서버가 공백으로 읽어 인증이 실패한다.
    ///    (증상이 "가끔 로그인이 안 됨" 이라 원인을 찾기 어렵다)
    static func formEncoded(_ fields: [String: String]) -> String {
        // RFC 3986 의 unreserved 문자만 남기고 전부 퍼센트 인코딩한다.
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
        }
        return fields
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
    }

    /// 파일로 내려받는다. 이미 있고 크기가 0보다 크면 건너뛴다(안드로이드와 같은 재개 규칙).
    /// - Returns: 실제로 내려받았으면 true, 이미 있어서 건너뛰었으면 false.
    @discardableResult
    static func download(_ urlString: String, to dest: URL) async throws -> Bool {
        if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int,
           size > 0 { return false }
        guard let url = URL(string: urlString) else { return false }

        Paths.ensureDir(dest.deletingLastPathComponent())
        let (tmp, response) = try await session.download(from: url)
        try check(response, url)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return true
    }

    /// 여러 후보 URL 을 순서대로 시도하고 첫 성공에서 멈춘다.
    /// Forge/Fabric 라이브러리가 메이븐 저장소 여러 곳에 흩어져 있어서 필요하다.
    @discardableResult
    static func downloadFirst(_ candidates: [String], to dest: URL) async -> Bool {
        for url in candidates {
            if (try? await download(url, to: dest)) != nil { return true }
        }
        return false
    }

    private static func check(_ response: URLResponse, _ url: URL, body: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw StatusError(code: http.statusCode, url: url.absoluteString, body: body)
        }
    }
}

extension URL {
    /// 문자열 URL 을 강제로 만드는 헬퍼 — 상수 URL 에만 쓴다.
    static func lit(_ s: String) -> URL { URL(string: s)! }
}
