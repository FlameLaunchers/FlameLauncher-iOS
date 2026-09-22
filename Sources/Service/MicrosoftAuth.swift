import Foundation
import UIKit
import Observation

/// 로그인 세션. 안드로이드 `AuthSession` 과 필드가 같다.
struct AuthSession: Codable {
    var username: String
    var uuid: String
    var accessToken: String
    var refreshToken: String
    /// epoch milliseconds — 안드로이드와 같은 단위로 둬서 세션 JSON 을 공유할 수 있다.
    var expiresAt: Double

    var isValid: Bool { Date().timeIntervalSince1970 * 1000 < expiresAt - 60_000 }

    /// 스킨 얼굴 이미지. 안드로이드 `loadSkinFace` 가 하던 일.
    /// 스킨 얼굴(모자 레이어 포함). 안드로이드 `loadSkinFace` 와 같은 서비스다.
    /// ⚠️ Crafatar 는 쓰지 않는다 — 500 을 내면서 **기본 스킨(Alex) 얼굴**을 돌려줘서, 로그인해도
    ///    내 스킨이 안 보였다(실측 2026-09-22). 이것도 끊기면 Mojang sessionserver 의 텍스처로 옮긴다.
    var faceURL: URL? { URL(string: "https://mc-heads.net/avatar/\(uuid)/128") }
}

/// Microsoft → Xbox Live → XSTS → Minecraft 토큰 체인.
///
/// ⚠️ 인증 코드는 **WKWebView 로 직접 가로챈다**(`MicrosoftLoginController`).
///    `ASWebAuthenticationSession` 은 커스텀 스킴만 가로채는데 이 client_id 의 리디렉션은
///    `https://login.live.com/oauth20_desktop.srf` 라서, 로그인을 마쳐도 그 https 페이지
///    ("일반적으로 표시되지 않는 페이지로 이동했습니다")에 멈춰 완료 핸들러가 안 불린다.
///
///    가로채는 방식이라 안드로이드판과 **같은 파라미터**를 쓸 수 있다:
///      - scope: `XboxLive.signin offline_access`
///      - RpsTicket: `d=<access_token>` (이 스코프는 접두사가 필요하다)
@Observable
@MainActor
final class AuthStore: NSObject {
    static let shared = AuthStore()

    static let clientId = "00000000402b5328"   // Xbox 공식 Client ID
    static let redirectURI = "https://login.live.com/oauth20_desktop.srf"
    static let scope = "XboxLive.signin offline_access"

    private static let keychainService = "kr.co.donghyun.flamelauncher.auth"
    private static let keychainAccount = "microsoft-session"

    private(set) var session: AuthSession?
    private(set) var isBusy = false
    /// 진행 단계 표시 ("Xbox Live 인증 중…"). 로그인은 5단계라 그냥 도는 것보다 낫다.
    private(set) var progress: String?
    var error: String?

    var isLoggedIn: Bool { session != nil }
    var username: String? { session?.username }
    var uuid: String? { session?.uuid }

    override private init() {
        super.init()
        session = Self.loadSession()
    }

    // MARK: - 저장 (키체인)

    private static func loadSession() -> AuthSession? {
        guard let data = Keychain.load(service: keychainService, account: keychainAccount) else {
            return migrateLegacyFile()
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private static func store(_ session: AuthSession?) {
        guard let session, let data = try? JSONEncoder().encode(session) else {
            Keychain.delete(service: keychainService, account: keychainAccount)
            return
        }
        Keychain.save(data, service: keychainService, account: keychainAccount)
    }

    /// 예전 버전이 평문 JSON 으로 저장해 둔 세션을 키체인으로 옮기고 파일은 지운다.
    private static func migrateLegacyFile() -> AuthSession? {
        let url = Paths.files.appending(path: "ms_auth.json")
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(AuthSession.self, from: data)
        else { return nil }
        store(session)
        try? FileManager.default.removeItem(at: url)
        return session
    }

    // MARK: - 세션 복원

    /// 앱 시작 시 호출. 만료됐으면 refresh token 으로 조용히 갱신한다.
    func restore() async {
        guard let current = session else { return }
        if current.isValid { return }
        guard !current.refreshToken.isEmpty else { logout(); return }

        do {
            session = try await refresh(current.refreshToken)
            Self.store(session)
        } catch let error as HTTP.StatusError where (400..<500).contains(error.code) {
            // 서버가 거절했다 = 갱신 토큰이 죽었다. 다시 로그인해야 한다.
            logout()
        } catch {
            // ⚠️ 네트워크 오류로 로그아웃시키면 안 된다 — 비행기/지하철에서 앱을 켰다는
            //    이유만으로 세션이 날아가 버린다. 세션은 남기고 다음 시도를 기다린다.
            self.error = "세션 갱신에 실패했습니다(네트워크). 오프라인 상태로 계속합니다."
        }
    }

    // MARK: - 로그인

    func login() async {
        isBusy = true
        error = nil
        defer { isBusy = false; progress = nil }

        do {
            let code = try await authorizationCode()
            progress = "Microsoft 토큰 요청 중…"
            let msToken = try await msToken(grant: ["code": code, "grant_type": "authorization_code"])
            session = try await completeChain(msToken)
            Self.store(session)
        } catch AuthError.cancelled {
            // 사용자가 그냥 닫은 것 — 오류로 표시하지 않는다.
        } catch {
            self.error = error.localizedDescription
        }
    }

    func logout() {
        session = nil
        Self.store(nil)
    }

    // MARK: - OAuth

    private func authorizationCode() async throws -> String {
        var comps = URLComponents(string: "https://login.live.com/oauth20_authorize.srf")!
        comps.queryItems = [
            .init(name: "client_id", value: Self.clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scope),
            .init(name: "prompt", value: "select_account"),
        ]

        guard let presenter = Self.topViewController() else {
            throw AuthError.cannotOpenBrowser
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let controller = MicrosoftLoginController(
                authURL: comps.url!, redirectPrefix: Self.redirectURI
            ) { result in
                // 시트 dismiss 와 콜백이 겹칠 수 있어 한 번만 통과시킨다.
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            let nav = UINavigationController(rootViewController: controller)
            nav.setNavigationBarHidden(true, animated: false)
            presenter.present(nav, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private struct MsToken: Decodable {
        let access_token: String
        let refresh_token: String?
    }

    private func msToken(grant: [String: String]) async throws -> MsToken {
        var fields = grant
        fields["client_id"] = Self.clientId
        fields["redirect_uri"] = Self.redirectURI
        fields["scope"] = Self.scope
        return try await HTTP.form(MsToken.self,
                                   url: .lit("https://login.live.com/oauth20_token.srf"),
                                   fields: fields)
    }

    private func refresh(_ refreshToken: String) async throws -> AuthSession {
        let token = try await msToken(grant: [
            "refresh_token": refreshToken, "grant_type": "refresh_token",
        ])
        return try await completeChain(token)
    }

    /// XBL → XSTS → Minecraft → 프로필. 안드로이드와 같은 5단계.
    private func completeChain(_ msToken: MsToken) async throws -> AuthSession {
        progress = "Xbox Live 인증 중…"
        let (xblToken, uhs) = try await xblToken(msToken.access_token)

        progress = "XSTS 토큰 요청 중…"
        let xsts = try await xstsToken(xblToken)

        progress = "마인크래프트 토큰 요청 중…"
        let mc = try await mcToken(uhs: uhs, xsts: xsts)

        progress = "프로필 확인 중…"
        let profile = try await mcProfile(mc.access_token)

        guard let name = profile.name, let id = profile.id else {
            throw AuthError.noProfile(profile.errorMessage)
        }
        return AuthSession(
            username: name, uuid: id,
            accessToken: mc.access_token,
            refreshToken: msToken.refresh_token ?? "",
            expiresAt: Date().timeIntervalSince1970 * 1000 + Double(mc.expires_in) * 1000
        )
    }

    private struct XblResponse: Decodable {
        struct Claims: Decodable {
            struct Xui: Decodable { let uhs: String }
            let xui: [Xui]
        }
        let Token: String
        let DisplayClaims: Claims
    }

    private func xblToken(_ accessToken: String) async throws -> (String, String) {
        // ⚠️ `XboxLive.signin` 스코프의 토큰은 반드시 `d=` 접두사를 붙여야 한다.
        //    (레거시 MBI_SSL 티켓이라면 접두사 없이 그대로 넣는다 — 섞으면 조용히 실패한다)
        let body: [String: Any] = [
            "Properties": [
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                "RpsTicket": "d=\(accessToken)",
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT",
        ]
        let response = try await HTTP.post(
            XblResponse.self,
            url: .lit("https://user.auth.xboxlive.com/user/authenticate"),
            body: try JSONSerialization.data(withJSONObject: body),
            contentType: "application/json"
        )
        guard let uhs = response.DisplayClaims.xui.first?.uhs else { throw AuthError.noUhs }
        return (response.Token, uhs)
    }

    private func xstsToken(_ xblToken: String) async throws -> String {
        let body: [String: Any] = [
            "Properties": ["SandboxId": "RETAIL", "UserTokens": [xblToken]],
            "RelyingParty": "rp://api.minecraftservices.com/",
            "TokenType": "JWT",
        ]
        do {
            return try await HTTP.post(
                XblResponse.self,
                url: .lit("https://xsts.auth.xboxlive.com/xsts/authorize"),
                body: try JSONSerialization.data(withJSONObject: body),
                contentType: "application/json"
            ).Token
        } catch let error as HTTP.StatusError {
            // XSTS 는 거절 사유를 본문의 XErr 코드로만 알려준다. 그대로 두면 사용자는
            // "요청 실패 (401)" 만 보게 된다 — 실제로는 대부분 계정 문제라 안내가 가능하다.
            throw AuthError.xsts(Self.xstsMessage(for: error))
        }
    }

    /// 테스트에서 직접 부를 수 있도록 internal 로 둔다 — 분기가 계정 상태마다 달라서
    /// 실제 로그인으로는 재현하기 어렵다.
    nonisolated static func xstsMessage(for error: HTTP.StatusError) -> String {
        let code = (error.json?["XErr"] as? NSNumber)?.int64Value ?? 0
        switch code {
        case 2_148_916_233:
            return "이 Microsoft 계정에 Xbox 프로필이 없습니다.\nxbox.com 에서 프로필을 먼저 만들어 주세요."
        case 2_148_916_235:
            return "Xbox Live 를 사용할 수 없는 국가/지역의 계정입니다."
        case 2_148_916_236, 2_148_916_237:
            return "성인 인증이 필요한 계정입니다. xbox.com 에서 인증을 마쳐 주세요."
        case 2_148_916_238:
            return "미성년자 계정입니다. 가족 구성원으로 추가되어야 로그인할 수 있습니다."
        default:
            return "Xbox Live 인증에 실패했습니다 (XErr \(code == 0 ? "알 수 없음" : String(code)))."
        }
    }

    private struct McToken: Decodable {
        let access_token: String
        let expires_in: Int
    }

    private func mcToken(uhs: String, xsts: String) async throws -> McToken {
        let body = ["identityToken": "XBL3.0 x=\(uhs);\(xsts)"]
        return try await HTTP.post(
            McToken.self,
            url: .lit("https://api.minecraftservices.com/authentication/login_with_xbox"),
            body: try JSONSerialization.data(withJSONObject: body),
            contentType: "application/json"
        )
    }

    private struct McProfile: Decodable {
        let id: String?
        let name: String?
        let errorMessage: String?
    }

    private func mcProfile(_ token: String) async throws -> McProfile {
        do {
            return try await HTTP.json(
                McProfile.self,
                from: .lit("https://api.minecraftservices.com/minecraft/profile"),
                headers: ["Authorization": "Bearer \(token)"])
        } catch let error as HTTP.StatusError where error.code == 404 {
            // 자바 에디션을 안 산 계정은 프로필이 아예 없다(404). 가장 흔한 실패라 따로 안내한다.
            throw AuthError.noProfile(nil)
        }
    }

    enum AuthError: LocalizedError, Equatable {
        case cancelled
        case cannotOpenBrowser
        case noCode
        case noUhs
        case authorize(String)
        case xsts(String)
        case noProfile(String?)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "로그인을 취소했습니다."
            case .cannotOpenBrowser: return "로그인 창을 열 수 없습니다."
            case .noCode: return "인증 코드를 받지 못했습니다."
            case .noUhs: return "Xbox Live 사용자 해시를 받지 못했습니다."
            case .authorize(let m): return "Microsoft 로그인 실패: \(m)"
            case .xsts(let m): return m
            case .noProfile(let m):
                return m ?? "이 계정에는 마인크래프트 자바 에디션 프로필이 없습니다.\n"
                          + "자바 에디션을 구매한 계정인지 확인해 주세요."
            }
        }
    }
}
