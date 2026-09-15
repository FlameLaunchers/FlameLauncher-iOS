import CoreGraphics

/// 가상 스틱의 방향 → WASD 변환. 게임 화면(GameControlsView)과 테스트가 같은 함수를 쓴다.
enum Joystick {
    static let w = 87, a = 65, s = 83, d = 68

    /// 각도를 8방위로 양자화해 W/A/S/D 조합을 만든다.
    /// 화면 좌표계라 위쪽이 -y — 각도 0 은 오른쪽(D)이다.
    static func keys(forAngle angle: CGFloat) -> Set<Int> {
        let sector = Int(((angle + .pi * 2 + .pi / 8) / (.pi / 4)).rounded(.down)) % 8
        switch sector {
        case 0: return [d]
        case 1: return [d, s]
        case 2: return [s]
        case 3: return [s, a]
        case 4: return [a]
        case 5: return [a, w]
        case 6: return [w]
        default: return [w, d]
        }
    }
}
