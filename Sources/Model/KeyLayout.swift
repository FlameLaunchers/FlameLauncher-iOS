import Foundation
import CoreGraphics

/// 화면 위 가상 키 버튼 하나. 안드로이드 `data.key.KeyButton` 과 필드가 같다
/// (좌표는 0~1 화면 비율, 크기는 52 단위 기준의 논리 크기).
struct KeyButton: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    /// GLFW 키코드. 음수는 런처 자체 액션(-6=키보드 토글, -7=전투모드, -8=메뉴).
    var glfwCode: Int
    var x: Double
    var y: Double
    var size: Double = 52          // 하위 호환용 (width/height 없을 때)
    var width: Double = 52
    var height: Double = 52
    var isAccent: Bool = false

    /// 런처 자체 액션 키인지 (게임으로 보내지 않고 런처가 처리).
    var isLauncherAction: Bool { glfwCode < 0 }
}

enum LauncherAction {
    static let softKeyboard = -6
    static let combatMode   = -7
    static let menu         = -8
}

enum KeyLayoutStore {
    /// 안드로이드 DEFAULT_LAYOUT 과 동일한 기본 배치.
    /// WASD 는 GameControlsView 에서 조이스틱 하나로 합쳐 그린다(안드로이드와 같은 처리).
    static let defaultLayout: [KeyButton] = [
        KeyButton(id: "w",        label: "W",   glfwCode: 87,  x: 0.14, y: 0.70),
        KeyButton(id: "a",        label: "A",   glfwCode: 65,  x: 0.06, y: 0.88),
        KeyButton(id: "s",        label: "S",   glfwCode: 83,  x: 0.14, y: 0.88),
        KeyButton(id: "d",        label: "D",   glfwCode: 68,  x: 0.22, y: 0.88),
        KeyButton(id: "jump",     label: "🔼",  glfwCode: 32,  x: 0.92, y: 0.88),
        KeyButton(id: "sneak",    label: "🔽",  glfwCode: 340, x: 0.76, y: 0.88),
        KeyButton(id: "sprint",   label: "⏫",  glfwCode: 341, x: 0.84, y: 0.88),
        KeyButton(id: "inv",      label: "E",   glfwCode: 69,  x: 0.92, y: 0.70),
        KeyButton(id: "esc",      label: "ESC", glfwCode: 256, x: 0.06, y: 0.10),
        KeyButton(id: "keyboard", label: "⌨️",  glfwCode: LauncherAction.softKeyboard, x: 0.14, y: 0.10),
        KeyButton(id: "f3",       label: "F3",  glfwCode: 292, x: 0.22, y: 0.10),
        KeyButton(id: "f5",       label: "F5",  glfwCode: 294, x: 0.30, y: 0.10),
        KeyButton(id: "t",        label: "T",   glfwCode: 84,  x: 0.06, y: 0.28),
        KeyButton(id: "slash",    label: "/",   glfwCode: 47,  x: 0.14, y: 0.28),
        KeyButton(id: "drop",     label: "Q",   glfwCode: 81,  x: 0.22, y: 0.28),
        KeyButton(id: "combat",   label: "⚔️",  glfwCode: LauncherAction.combatMode, x: 0.84, y: 0.70, isAccent: true),
        KeyButton(id: "menu",     label: "☰",   glfwCode: LauncherAction.menu, x: 0.38, y: 0.10),
    ]

    private static let file = JSONFile(name: "key_layout.json", fallback: defaultLayout)

    static func load() -> [KeyButton] {
        let loaded = file.load()
        return loaded.isEmpty ? defaultLayout : loaded
    }

    static func save(_ layout: [KeyButton]) { file.save(layout) }

    @discardableResult
    static func reset() -> [KeyButton] { save(defaultLayout); return defaultLayout }
}

/// 화면 크기에 맞춘 버튼 실측 크기. 안드로이드 GameControllerView / KeyBoardEditorScreen 이
/// 공유하던 상수와 공식을 그대로 옮겼다 — 두 화면의 버튼 크기가 어긋나면 편집 결과가
/// 실제 게임 화면과 달라진다.
enum KeyMetrics {
    static let baseUnit: Double = 52
    static let targetTablet: Double = 76
    static let targetPhone: Double = 48
    static let targetCompact: Double = 40   // 접근성 최소 터치 타깃(40pt) 아래로는 안 내려간다

    static var baseScale: Double {
        Sizing.pick(targetTablet, targetPhone, targetCompact) / baseUnit
    }

    static func rect(for button: KeyButton, in size: CGSize) -> CGRect {
        let s = baseScale
        let w = button.width * s
        let h = button.height * s
        return CGRect(
            x: button.x * size.width - w / 2,
            y: button.y * size.height - h / 2,
            width: w, height: h
        )
    }
}
