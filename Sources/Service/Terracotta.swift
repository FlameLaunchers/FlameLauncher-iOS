import Foundation
import Observation

/// 테라코타(온라인 LAN) 제어.
///
/// 안드로이드는 JNI 로 함수 하나하나를 불렀지만(`TerracottaAndroidAPI` 의 native 메서드 10개),
/// 테라코타는 **제어 표면을 이미 HTTP 로 전부 내놓고 있다** — 데스크톱 UI 가 그걸 쓴다.
/// 그래서 네이티브 진입점은 서버를 띄우는 `terracotta_ios_start` 하나뿐이고,
/// 나머지는 여기서 `http://127.0.0.1:<포트>/state/…` 로 부른다.
/// 호출마다 FFI 를 손으로 짜는 것보다 표면이 작고, 업스트림이 API 를 바꿔도 깨질 자리가 적다.
///
/// ⚠️ TUN 은 쓰지 않는다. iOS 에서 TUN 은 Network Extension 뿐인데 그 권한은
///    무료 개발자 계정으로 서명이 안 된다. 그래서 **방장 노릇은 되고, 참가는
///    가상 IP 로 직접 못 건다**(EasyTier no-TUN 모드의 문서화된 제약).
@Observable
@MainActor
final class Terracotta {
    static let shared = Terracotta()

    private(set) var state: State = .stopped
    private(set) var port: UInt16 = 0
    /// 사용자에게 보여줄 마지막 실패 사유.
    private(set) var failure: String?

    private var poller: Task<Void, Never>?

    private init() {}

    // MARK: - 상태

    /// 테라코타가 돌려주는 상태. `state` 문자열이 판별자다.
    ///
    /// 안드로이드는 Gson TypeAdapterFactory 로 sealed class 를 갈랐지만, 스위프트는
    /// 판별자 하나로 충분하다 — 페이로드가 다른 건 host-ok / guest-ok / exception 셋뿐이다.
    enum State: Equatable {
        case stopped                  // 아직 안 띄웠다
        case waiting                  // 대기(아무것도 안 하는 중)
        case hostScanning             // 방장: 열린 LAN 월드를 찾는 중
        case hostStarting             // 방장: 연결 준비 중
        case hostOK(room: String)     // 방장: 방 코드가 나왔다
        case guestConnecting          // 게스트: 붙는 중
        case guestStarting            // 게스트: 준비 중
        case guestOK(url: String?)    // 게스트: 접속 주소가 나왔다
        case failed(String)           // 테라코타가 보고한 오류

        var isBusy: Bool {
            switch self {
            case .hostScanning, .hostStarting, .guestConnecting, .guestStarting: return true
            default: return false
            }
        }
    }

    /// 테라코타가 보고하는 오류 종류. 순서가 곧 프로토콜의 정수값이다 — 바꾸지 말 것.
    private static let exceptionMessages = [
        "방장에게 연결하지 못했습니다",
        "방장과의 연결이 끊어졌습니다",
        "게스트 쪽 네트워크가 중단됐습니다",
        "방장 쪽 네트워크가 중단됐습니다",
        "서버와의 연결이 끊어졌습니다",
        "중계 서버가 잘못된 응답을 보냈습니다",
    ]

    // MARK: - 수명

    /// 네이티브 서버를 띄운다. 이미 떠 있으면 아무것도 하지 않는다.
    ///
    /// ⚠️ 한 프로세스에서 한 번만 뜬다(로켓을 두 번 띄우면 패닉한다). 그래서 성공한 뒤에는
    ///    화면을 닫았다 열어도 다시 부르지 않는다 — 폴링만 멈췄다 재개한다.
    func start() {
        guard port == 0 else { startPolling(); return }

        let dir = Paths.caches.appending(path: "terracotta")
        let opened: UInt16 = dir.path.withCString { terracotta_ios_start($0) }
        guard opened != 0 else {
            failure = "테라코타를 시작하지 못했습니다."
            state = .stopped
            return
        }
        port = opened
        failure = nil
        startPolling()
    }

    /// 화면을 떠날 때 폴링만 멈춘다. 네이티브 서버는 계속 돈다 —
    /// 방을 열어 둔 채로 게임에 들어가는 게 정상 사용 흐름이다.
    func pausePolling() {
        poller?.cancel()
        poller = nil
    }

    private func startPolling() {
        guard poller == nil, port != 0 else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    // MARK: - 명령

    /// 대기 상태로 되돌린다(방 닫기 / 접속 끊기).
    func reset() async { await command("/state/ide") }

    /// 방장: 열린 LAN 월드를 찾아 방을 연다.
    /// - Parameter player: 표시용 이름. 비우면 테라코타가 알아서 정한다.
    func host(player: String?) async {
        var items: [URLQueryItem] = []
        if let player, !player.isEmpty { items.append(URLQueryItem(name: "player", value: player)) }
        await command("/state/scanning", query: items)
    }

    /// 게스트: 방 코드로 참가한다.
    func join(room: String, player: String?) async {
        var items = [URLQueryItem(name: "room", value: room)]
        if let player, !player.isEmpty { items.append(URLQueryItem(name: "player", value: player)) }
        await command("/state/guesting", query: items)
    }

    // MARK: - HTTP

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    private func command(_ path: String, query: [URLQueryItem] = []) async {
        guard port != 0, let url = url(path, query: query) else { return }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            // 방 코드가 틀리면 테라코타가 400 을 돌려준다. 조용히 삼키면
            // "눌렀는데 아무 일도 안 일어남" 이 된다.
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                failure = http.statusCode == 400 ? "방 코드를 확인해주세요." : "요청이 거부됐습니다 (\(http.statusCode))."
                return
            }
            failure = nil
            await refresh()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func refresh() async {
        guard port != 0, let url = url("/state/") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        state = Self.parse(root)
    }

    /// - Note: `internal` 이라 테스트가 직접 부를 수 있다. 이 계층에서 로직다운 건 여기뿐이다.
    static func parse(_ root: [String: Any]) -> State {
        switch root["state"] as? String {
        case "waiting":          return .waiting
        case "host-scanning":    return .hostScanning
        case "host-starting":    return .hostStarting
        case "host-ok":
            // 방 코드가 없는 host-ok 는 프로토콜 위반이다. 빈 코드를 보여주느니
            // 준비 중으로 둔다 — 사용자가 빈 칸을 복사하는 게 더 나쁘다.
            guard let room = root["room"] as? String, !room.isEmpty else { return .hostStarting }
            return .hostOK(room: room)
        case "guest-connecting": return .guestConnecting
        case "guest-starting":   return .guestStarting
        case "guest-ok":         return .guestOK(url: root["url"] as? String)
        case "exception":
            let type = root["type"] as? Int ?? -1
            let message = exceptionMessages.indices.contains(type)
                ? exceptionMessages[type]
                : "알 수 없는 오류가 발생했습니다"
            return .failed(message)
        default:                 return .stopped
        }
    }
}
