import Foundation

/// 안드로이드 `data.setting.Setting` 이식.
struct AppSettings: Codable {
    var neverShowCautionAgain: Bool = false
    /// 사용자가 "이 버전 건너뛰기"를 누른 업데이트 태그(예: "v2.0.0").
    var skippedUpdateVersion: String?
    /// 화면 컨트롤러 표시 여부 — 안드로이드는 SharedPreferences("flame_controller") 였다.
    var controllerVisible: Bool = true
}

enum AppSettingsStore {
    private static let file = JSONFile(name: "setting.json", fallback: AppSettings())
    static func load() -> AppSettings { file.load() }
    static func save(_ s: AppSettings) { file.save(s) }
}
