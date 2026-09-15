import Foundation
import Security

/// 키체인에 값 하나를 넣고 빼는 최소 래퍼.
///
/// 로그인 세션에는 마인크래프트 접근 토큰과 MSA 갱신 토큰이 들어 있다. 이걸 파일로 두면
/// 기기 백업·파일 앱·다른 앱의 컨테이너 접근 경로로 새어나갈 수 있어서 키체인에 넣는다.
/// (`kSecAttrAccessibleAfterFirstUnlock` — 게임이 백그라운드에서 갱신할 수 있어야 한다)
enum Keychain {
    static func save(_ data: Data, service: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)

        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(service: String, account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
