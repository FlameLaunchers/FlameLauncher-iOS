import Foundation

/// 앱 표시 언어. 시스템 언어를 따르거나(기본), 영어·한국어로 고정한다.
///
/// ⚠️ 왜 앱 안에 두는가 — 게임을 실행하면 JIT 때문에 앱이 스스로 다시 뜨는 구간이 있는데,
///    `-AppleLanguages` 실행 인자로 준 언어는 그때 사라진다. 여기서 UserDefaults 에 적어 두면
///    다시 떠도 그대로 유지된다(iOS 설정 → 앱 → 언어와 같은 자리에 쓰는 값이다).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, korean

    var id: String { rawValue }

    /// 설정 화면에 보일 이름. 각 언어는 제 이름으로 적는다 — 지금 어떤 언어로 떠 있든 고를 수 있게.
    var displayName: String {
        switch self {
        case .system:  return String(localized: "시스템 언어")
        case .english: return "English"
        case .korean:  return "한국어"
        }
    }

    /// UserDefaults 의 AppleLanguages 에 넣을 값. system 이면 지운다.
    var codes: [String]? {
        switch self {
        case .system:  return nil
        case .english: return ["en"]
        case .korean:  return ["ko"]
        }
    }

    private static let key = "AppleLanguages"

    /// 지금 고정된 언어. 아무것도 고정하지 않았으면 system.
    static var current: AppLanguage {
        guard let saved = UserDefaults.standard.object(forKey: key) as? [String],
              let first = saved.first
        else { return .system }
        return first.hasPrefix("ko") ? .korean : first.hasPrefix("en") ? .english : .system
    }

    /// 고른 언어를 저장한다. 이미 떠 있는 화면은 그대로이고, 앱을 다시 열면 바뀐다
    /// (iOS 는 번들 번역을 앱 시작 때 한 번 고른다).
    static func apply(_ language: AppLanguage) {
        if let codes = language.codes {
            UserDefaults.standard.set(codes, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()
    }
}
