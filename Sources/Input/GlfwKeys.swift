import UIKit

/// GLFW 키/마우스 상수 + iOS 하드웨어 키보드(HID usage) → GLFW 키코드 매핑.
///
/// 마인크래프트(LWJGL/GLFW)는 키를 GLFW 키코드로 받는다. 안드로이드 판과 마찬가지로
/// 연속 구간(A~Z, 0~9, F1~F12, 넘패드)은 산술로 처리하고 나머지만 표로 둔다 —
/// 100줄짜리 표보다 짧고, 오타로 한 글자가 빠질 여지도 없다.
enum GlfwKeys {

    // ── GLFW 액션 ──
    static let release = 0
    static let press = 1

    // ── GLFW 수식키 비트 ──
    static let modShift = 0x0001
    static let modControl = 0x0002
    static let modAlt = 0x0004
    static let modSuper = 0x0008

    // ── GLFW 마우스 버튼 ──
    static let mouseLeft = 0
    static let mouseRight = 1
    static let mouseMiddle = 2

    // ── GLFW 키코드 (자주 쓰는 것만 이름 부여) ──
    static let space = 32
    static let zero = 48
    static let a = 65
    static let escape = 256
    static let enter = 257
    static let tab = 258
    static let backspace = 259
    static let insert = 260
    static let delete = 261
    static let right = 262
    static let left = 263
    static let down = 264
    static let up = 265
    static let pageUp = 266
    static let pageDown = 267
    static let home = 268
    static let end = 269
    static let capsLock = 280
    static let scrollLock = 281
    static let numLock = 282
    static let printScreen = 283
    static let pause = 284
    static let f1 = 290
    static let kp0 = 320
    static let kpDecimal = 330
    static let kpDivide = 331
    static let kpMultiply = 332
    static let kpSubtract = 333
    static let kpAdd = 334
    static let kpEnter = 335
    static let leftShift = 340
    static let leftControl = 341
    static let leftAlt = 342
    static let leftSuper = 343
    static let rightShift = 344
    static let rightControl = 345
    static let rightAlt = 346
    static let rightSuper = 347
    static let menu = 348

    /// iOS `UIKeyboardHIDUsage` → GLFW 키코드. 매핑 없으면 nil.
    ///
    /// 연속 구간은 HID/GLFW 양쪽 다 연속이라 오프셋 산술로 처리한다:
    ///   keyboardA(0x04)..keyboardZ(0x1D)        → 65..90
    ///   keyboard1(0x1E)..keyboard9(0x26)        → 49..57   (HID 는 1부터, 0 은 따로)
    ///   keyboardF1(0x3A)..keyboardF12(0x45)     → 290..301
    ///   keypad1(0x59)..keypad9(0x61)            → 321..329 (HID 는 1부터, 0 은 따로)
    static func fromHID(_ usage: UIKeyboardHIDUsage) -> Int? {
        let raw = usage.rawValue

        switch raw {
        case UIKeyboardHIDUsage.keyboardA.rawValue...UIKeyboardHIDUsage.keyboardZ.rawValue:
            return a + (raw - UIKeyboardHIDUsage.keyboardA.rawValue)
        case UIKeyboardHIDUsage.keyboard1.rawValue...UIKeyboardHIDUsage.keyboard9.rawValue:
            return zero + 1 + (raw - UIKeyboardHIDUsage.keyboard1.rawValue)
        case UIKeyboardHIDUsage.keyboardF1.rawValue...UIKeyboardHIDUsage.keyboardF12.rawValue:
            return f1 + (raw - UIKeyboardHIDUsage.keyboardF1.rawValue)
        case UIKeyboardHIDUsage.keypad1.rawValue...UIKeyboardHIDUsage.keypad9.rawValue:
            return kp0 + 1 + (raw - UIKeyboardHIDUsage.keypad1.rawValue)
        default: break
        }

        switch usage {
        case .keyboard0: return zero
        case .keypad0: return kp0

        // 기호 (GLFW 는 US 배열 기준 ASCII 값을 그대로 쓴다)
        case .keyboardSpacebar: return space
        case .keyboardQuote: return 39
        case .keyboardComma: return 44
        case .keyboardHyphen: return 45
        case .keyboardPeriod: return 46
        case .keyboardSlash: return 47
        case .keyboardSemicolon: return 59
        case .keyboardEqualSign: return 61
        case .keyboardOpenBracket: return 91
        case .keyboardBackslash: return 92
        case .keyboardCloseBracket: return 93
        case .keyboardGraveAccentAndTilde: return 96

        // 편집/이동
        case .keyboardEscape: return escape
        case .keyboardReturnOrEnter: return enter
        case .keypadEnter: return kpEnter
        case .keyboardTab: return tab
        case .keyboardDeleteOrBackspace: return backspace
        case .keyboardDeleteForward: return delete
        case .keyboardInsert: return insert
        case .keyboardRightArrow: return right
        case .keyboardLeftArrow: return left
        case .keyboardDownArrow: return down
        case .keyboardUpArrow: return up
        case .keyboardPageUp: return pageUp
        case .keyboardPageDown: return pageDown
        case .keyboardHome: return home
        case .keyboardEnd: return end

        // 토글/시스템
        case .keyboardCapsLock: return capsLock
        case .keyboardScrollLock: return scrollLock
        case .keypadNumLock: return numLock
        case .keyboardPrintScreen: return printScreen
        case .keyboardPause: return pause
        case .keyboardApplication: return menu

        // 수식키 (좌/우 구분)
        case .keyboardLeftShift: return leftShift
        case .keyboardRightShift: return rightShift
        case .keyboardLeftControl: return leftControl
        case .keyboardRightControl: return rightControl
        case .keyboardLeftAlt: return leftAlt
        case .keyboardRightAlt: return rightAlt
        case .keyboardLeftGUI: return leftSuper
        case .keyboardRightGUI: return rightSuper

        // 넘패드 연산자
        case .keypadPeriod: return kpDecimal
        case .keypadSlash: return kpDivide
        case .keypadAsterisk: return kpMultiply
        case .keypadHyphen: return kpSubtract
        case .keypadPlus: return kpAdd

        default: return nil
        }
    }

    /// UIKeyModifierFlags → GLFW mods 비트.
    static func mods(from flags: UIKeyModifierFlags) -> Int {
        var m = 0
        if flags.contains(.shift)   { m |= modShift }
        if flags.contains(.control) { m |= modControl }
        if flags.contains(.alternate) { m |= modAlt }
        if flags.contains(.command) { m |= modSuper }
        return m
    }

    /// 소프트 키보드에서 들어온 문자를 GLFW 키코드로. 채팅 입력용.
    static func fromCharacter(_ c: Character) -> Int? {
        guard let ascii = c.asciiValue else { return nil }
        if c.isLetter { return Int(Character(c.uppercased()).asciiValue ?? ascii) }
        return Int(ascii)
    }

    /// GLFW 키코드 → LWJGL 이 기대하는 scancode. 안드로이드 `getScancode` 와 동일 규칙:
    /// 대부분의 키에서 마인크래프트는 scancode 를 보지 않지만, 0 을 넘기면 일부
    /// 키 바인딩 화면이 "미설정"으로 표시되므로 키코드를 그대로 되돌려준다.
    static func scancode(for key: Int) -> Int { key }
}

/// 편집기의 "키 추가" 목록. 안드로이드 GlfwKeysAll 대응 —
/// 사용자가 화면 버튼으로 올릴 수 있는 키 전체.
enum GlfwKeyCatalog {
    struct KeyInfo: Identifiable, Hashable {
        let code: Int
        let label: String
        let group: String
        var id: Int { code }
    }

    static let all: [KeyInfo] = {
        var out: [KeyInfo] = []
        for (i, ch) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            out.append(KeyInfo(code: GlfwKeys.a + i, label: String(ch), group: "문자"))
        }
        for i in 0...9 {
            out.append(KeyInfo(code: GlfwKeys.zero + i, label: String(i), group: "숫자"))
        }
        for i in 0..<12 {
            out.append(KeyInfo(code: GlfwKeys.f1 + i, label: "F\(i + 1)", group: "기능키"))
        }
        out += [
            KeyInfo(code: GlfwKeys.space, label: "Space", group: "제어"),
            KeyInfo(code: GlfwKeys.escape, label: "ESC", group: "제어"),
            KeyInfo(code: GlfwKeys.enter, label: "Enter", group: "제어"),
            KeyInfo(code: GlfwKeys.tab, label: "Tab", group: "제어"),
            KeyInfo(code: GlfwKeys.backspace, label: "⌫", group: "제어"),
            KeyInfo(code: GlfwKeys.leftShift, label: "Shift", group: "제어"),
            KeyInfo(code: GlfwKeys.leftControl, label: "Ctrl", group: "제어"),
            KeyInfo(code: GlfwKeys.leftAlt, label: "Alt", group: "제어"),
            KeyInfo(code: GlfwKeys.up, label: "↑", group: "방향"),
            KeyInfo(code: GlfwKeys.down, label: "↓", group: "방향"),
            KeyInfo(code: GlfwKeys.left, label: "←", group: "방향"),
            KeyInfo(code: GlfwKeys.right, label: "→", group: "방향"),
            KeyInfo(code: 47, label: "/", group: "기호"),
            KeyInfo(code: 44, label: ",", group: "기호"),
            KeyInfo(code: 46, label: ".", group: "기호"),
            KeyInfo(code: LauncherAction.softKeyboard, label: "⌨️ 키보드", group: "런처"),
            KeyInfo(code: LauncherAction.combatMode, label: "⚔️ 전투", group: "런처"),
            KeyInfo(code: LauncherAction.menu, label: "☰ 메뉴", group: "런처"),
        ]
        return out
    }()

    static var grouped: [(String, [KeyInfo])] {
        let order = ["런처", "제어", "문자", "숫자", "기능키", "방향", "기호"]
        let dict = Dictionary(grouping: all, by: \.group)
        return order.compactMap { key in dict[key].map { (key, $0) } }
    }
}

/// 화면 터치 한 번이 어느 마우스 버튼이 되는지.
///
/// 안드로이드 `MinecraftSurface` 와 **같은 규칙**이다 — 탭과 롱프레스가 서로 반대다:
///
/// | 모드 | 탭 | 길게 누르기 |
/// |---|---|---|
/// | 일반 | 우클릭 (놓기·상호작용) | 좌클릭 유지 (채굴) |
/// | 전투 | 좌클릭 (공격) | 우클릭 유지 (방패·활·먹기) |
///
/// ⚠️ 둘을 같은 버튼으로 두면 일반 모드에서 **우클릭이 아예 나가지 않는다.**
///    음식 먹기처럼 우클릭을 1.6초 붙잡아야 하는 동작이 통째로 불가능해진다(실제로 그랬다).
///
/// grab 이 아닐 때(메뉴·인벤토리)는 언제나 좌클릭이다 — 마인크래프트 GUI 는 좌클릭으로 동작하고,
/// 우클릭을 보내면 "설정" 같은 버튼이 눌리지 않는다.
enum TouchButton {
    static func tap(combatMode: Bool, grabbing: Bool) -> Int {
        guard grabbing else { return GlfwKeys.mouseLeft }
        return combatMode ? GlfwKeys.mouseLeft : GlfwKeys.mouseRight
    }

    static func hold(combatMode: Bool, grabbing: Bool) -> Int {
        guard grabbing else { return GlfwKeys.mouseLeft }
        return combatMode ? GlfwKeys.mouseRight : GlfwKeys.mouseLeft
    }
}
