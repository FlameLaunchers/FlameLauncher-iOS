import SwiftUI

/// 화면 위 가상 컨트롤러. 안드로이드 `GameControllerView`(Canvas 직접 그리기) 이식.
///
/// 안드로이드는 View 를 상속해 onDraw 로 직접 그리고 dispatchTouchEvent 로 포인터를
/// SurfaceView 와 나눠 가졌는데, SwiftUI 에서는 오버레이 뷰가 자기 영역만 히트테스트하므로
/// 그 포인터 분배 코드(약 200줄)가 통째로 필요 없어졌다.
///
/// 유지한 동작:
///  - WASD 는 개별 버튼 대신 조이스틱 하나로 통합(8방위 양자화)
///  - 🎮 토글은 항상 그려지고 항상 눌린다 (꺼도 다시 켤 수 있어야 하므로)
///  - grab/IME 가 아닐 때(메뉴/인벤토리) ESC 전용 모드
///  - 앉기(Shift)는 토글, 컨트롤러를 숨기면 눌린 키를 전부 해제
struct GameControlsView: View {
    let runtime: JavaRuntime
    @Binding var visible: Bool
    /// 메뉴/인벤토리 상태 — ESC 버튼만 남긴다.
    let escOnlyMode: Bool
    let fps: Int
    /// jetsam 까지 남은 여유(MB). -1 이면 표시하지 않는다.
    let freeMemoryMb: Int
    let onMenu: () -> Void
    let onSoftKeyboard: () -> Void
    let onCombatToggle: () -> Void
    let combatMode: Bool

    @State private var layout = KeyLayoutStore.load()
    @State private var pressed: Set<String> = []
    @State private var sneakToggled = false
    @State private var joystick = JoystickState()

    private static let moveKeys = [87, 65, 83, 68]   // W A S D

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // ⚠️ 가로 모드에서는 노치/다이내믹 아일랜드가 **옆면**에 온다.
            //    top 만 피하면 왼쪽(또는 오른쪽) 인셋 59pt 아래로 컨트롤이 들어가 가려진다.
            //    네 방향을 모두 뺀 사각형 안에서만 배치한다.
            let safe = geo.safeAreaInsets
            let area = CGRect(x: safe.leading, y: safe.top,
                              width: max(0, size.width - safe.leading - safe.trailing),
                              height: max(0, size.height - safe.top - safe.bottom))

            ZStack(alignment: .topLeading) {
                if fps >= 0 {
                    fpsBadge.position(x: area.midX, y: area.minY + 18)
                }

                if visible {
                    JoystickPad(state: $joystick, center: joystickCenter(in: area),
                                radius: joystickRadius)
                        .onChange(of: joystick.activeKeys) { old, new in
                            applyMoveKeys(old: old, new: new)
                        }

                    ForEach(buttons) { button in
                        let rect = KeyMetrics.rect(for: button, in: size)
                        // 토글식 버튼(전투 모드·웅크리기)은 켜져 있는 동안 눌린 색으로 둔다 —
                        // 상태가 안 보이면 눌러도 안 바뀐 것처럼 느껴진다.
                        KeyButtonView(button: button,
                                      pressed: pressed.contains(button.id) || isLatched(button))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .gesture(pressGesture(button))
                    }
                }

                // 🎮 토글은 컨트롤러를 꺼도 남아야 다시 켤 수 있다.
                // 오른쪽 위 — 왼손 조이스틱·오른손 시야 조작 어느 쪽과도 안 겹친다.
                toggleButton.position(x: area.maxX - 26, y: area.minY + 26)
            }
        }
        .allowsHitTesting(true)
        .onChange(of: visible) { _, isVisible in
            if !isVisible { releaseAll() }
        }
        .onDisappear(perform: releaseAll)
    }

    /// 실제로 그릴 버튼들. WASD 는 조이스틱이 대신하므로 제외하고,
    /// 메뉴/인벤토리 상태에서는 ESC 만 남긴다.
    private var buttons: [KeyButton] {
        layout
            .filter { !Self.moveKeys.contains($0.glfwCode) }
            // grab 이 아닐 때(메뉴·인벤토리·서버 목록)는 게임 키를 숨긴다.
            // 다만 ESC·키보드·메뉴는 남겨야 한다 — 서버 주소를 입력하려면 키보드가 필요하다.
            .filter {
                !escOnlyMode
                    || $0.glfwCode == GlfwKeys.escape
                    || $0.glfwCode == LauncherAction.softKeyboard
                    || $0.glfwCode == LauncherAction.menu
            }
    }

    private var fpsBadge: some View {
        HStack(spacing: 6) {
            Text("\(fps) FPS")
            if freeMemoryMb >= 0 {
                // ⚠️ iOS 는 앱용 swap 이 없다. 이 값이 0 에 닿으면 경고 없이 SIGKILL 이다
                //    (자바 OutOfMemoryError 가 아니라 로그가 그냥 끊긴다).
                Text("· \(freeMemoryMb)MB")
                    .foregroundStyle(freeMemoryMb < 200 ? FlameColor.red
                                     : freeMemoryMb < 400 ? .orange : .white)
            }
        }
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var toggleButton: some View {
        Button { visible.toggle() } label: {
            Text("🎮")
                .font(.system(size: 18))
                .frame(width: 44, height: 44)
                .background(FlameColor.bgSurface.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(FlameColor.bgBorder.opacity(0.7),
                                         lineWidth: 2))
                .opacity(visible ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 조이스틱

    private var joystickRadius: CGFloat { KeyMetrics.baseScale * 78 }

    /// 스틱 중심은 WASD 버튼들의 중심 — 안드로이드와 같은 위치에 놓는다.
    /// 배치 비율은 **안전 영역 기준**으로 푼다 — 화면 전체 기준으로 풀면
    /// 가로 모드에서 스틱이 노치 아래로 들어간다.
    private func joystickCenter(in area: CGRect) -> CGPoint {
        let move = layout.filter { Self.moveKeys.contains($0.glfwCode) }
        let fx: Double, fy: Double
        if move.isEmpty {
            (fx, fy) = (0.14, 0.79)
        } else {
            fx = move.map(\.x).reduce(0, +) / Double(move.count)
            fy = move.map(\.y).reduce(0, +) / Double(move.count)
        }
        // 스틱이 가장자리를 넘지 않게 반지름만큼 여유를 둔다.
        let r = joystickRadius
        return CGPoint(x: min(max(area.minX + fx * area.width, area.minX + r), area.maxX - r),
                       y: min(max(area.minY + fy * area.height, area.minY + r), area.maxY - r))
    }

    /// 눌린 상태를 유지해야 하는 버튼인지.
    private func isLatched(_ button: KeyButton) -> Bool {
        switch button.glfwCode {
        case LauncherAction.combatMode: return combatMode
        case GlfwKeys.leftShift:        return sneakToggled
        default:                        return false
        }
    }

    private func applyMoveKeys(old: Set<Int>, new: Set<Int>) {
        for key in old.subtracting(new) { runtime.sendKey(key, action: GlfwKeys.release, mods: 0) }
        for key in new.subtracting(old) { runtime.sendKey(key, action: GlfwKeys.press, mods: 0) }
    }

    // MARK: - 버튼 입력

    private func pressGesture(_ button: KeyButton) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressed.contains(button.id) else { return }
                pressed.insert(button.id)
                handle(button, down: true)
            }
            .onEnded { _ in
                pressed.remove(button.id)
                handle(button, down: false)
            }
    }

    private func handle(_ button: KeyButton, down: Bool) {
        switch button.glfwCode {
        case LauncherAction.menu:
            if down { onMenu() }
        case LauncherAction.softKeyboard:
            if down { onSoftKeyboard() }
        case LauncherAction.combatMode:
            if down { onCombatToggle() }
        case GlfwKeys.leftShift:
            // 앉기는 토글 — 누르고 있기가 불편해서 안드로이드도 토글로 바꿨다.
            guard down else { return }
            sneakToggled.toggle()
            runtime.sendKey(GlfwKeys.leftShift,
                            action: sneakToggled ? GlfwKeys.press : GlfwKeys.release, mods: 0)
        default:
            runtime.sendKey(button.glfwCode,
                            action: down ? GlfwKeys.press : GlfwKeys.release, mods: 0)
        }
    }

    /// 눌린 것으로 기록된 입력을 전부 뗌 처리. 컨트롤러를 숨기면 버튼으로 끌 수 없으므로
    /// 여기서 정리하지 않으면 W 나 Shift 가 눌린 채로 남는다.
    private func releaseAll() {
        for id in pressed {
            if let button = layout.first(where: { $0.id == id }), !button.isLauncherAction {
                runtime.sendKey(button.glfwCode, action: GlfwKeys.release, mods: 0)
            }
        }
        pressed.removeAll()
        for key in joystick.activeKeys { runtime.sendKey(key, action: GlfwKeys.release, mods: 0) }
        joystick = JoystickState()
        if sneakToggled {
            sneakToggled = false
            runtime.sendKey(GlfwKeys.leftShift, action: GlfwKeys.release, mods: 0)
        }
    }
}

// MARK: - 버튼 한 개

private struct KeyButtonView: View {
    let button: KeyButton
    let pressed: Bool

    var body: some View {
        Text(button.label)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(border, lineWidth: 2)
            )
    }

    // ⚠️ 예전에는 안드로이드 Paint 값을 RGB 그대로 박아 뒀다(마젠타 계열). 그래서 팔레트를
    //    푸른 불꽃으로 갈아엎어도 **인게임 버튼만 마젠타로 남았다.** 팔레트를 거치게 바꾼다.
    private var fill: Color {
        switch (button.isAccent, pressed) {
        case (true, true):   return FlameColor.accent                    // 강조 + 눌림
        case (true, false):  return FlameColor.dark.opacity(0.85)        // 강조
        case (false, true):  return FlameColor.primary                   // 눌림
        case (false, false): return FlameColor.bgSurface.opacity(0.85)   // 기본
        }
    }

    private var border: Color {
        (button.isAccent ? FlameColor.light : FlameColor.bgBorder).opacity(0.7)
    }
}

// MARK: - 조이스틱

struct JoystickState: Equatable {
    var knob: CGPoint = .zero      // 중심 기준 오프셋
    var activeKeys: Set<Int> = []
    var isActive = false
}

/// WASD 를 대신하는 가상 스틱. knob 방향을 8방위로 양자화해 키 누름으로 바꾼다.
private struct JoystickPad: View {
    @Binding var state: JoystickState
    let center: CGPoint
    let radius: CGFloat

    private var deadZone: CGFloat { radius * 0.28 }
    private var knobRadius: CGFloat { radius * 0.42 }

    var body: some View {
        ZStack {
            Circle()
                .fill(FlameColor.bgSurface.opacity(state.isActive ? 0.55 : 0.35))
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 2))
                .frame(width: radius * 2, height: radius * 2)

            // 방향 힌트
            ForEach(Array(["W", "D", "S", "A"].enumerated()), id: \.offset) { index, label in
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .offset(
                        x: [0, radius - 12, 0, -(radius - 12)][index],
                        y: [-(radius - 12), 0, radius - 12, 0][index]
                    )
            }

            Circle()
                .fill(FlameColor.primary.opacity(state.isActive ? 0.95 : 0.6))
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 2))
                .frame(width: knobRadius * 2, height: knobRadius * 2)
                .offset(x: state.knob.x, y: state.knob.y)
        }
        .frame(width: radius * 2, height: radius * 2)
        // ⚠️ 제스처는 `.position` **앞에** 붙여야 한다. 뒤에 붙이면 value.location 이
        //    조이스틱 박스가 아니라 부모(화면 전체) 좌표로 들어와서, 좌하단에 있는
        //    스틱 기준으로 dx·dy 가 항상 우하향이 된다 — 어느 쪽을 당겨도 S(뒤로)만
        //    눌리고 노브도 가장자리에 붙어버린다.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.location.x - radius
                    let dy = value.location.y - radius
                    let distance = hypot(dx, dy)
                    let clamped = min(distance, radius)
                    let angle = atan2(dy, dx)
                    state.isActive = true
                    state.knob = CGPoint(x: cos(angle) * clamped, y: sin(angle) * clamped)
                    state.activeKeys = distance < deadZone ? [] : Self.keys(forAngle: angle)
                }
                .onEnded { _ in
                    state = JoystickState()
                }
        )
        .position(center)
    }

    /// 각도 → WASD 는 `Joystick` 이 단일 소스다(게임 화면과 테스트가 같은 함수를 쓴다).
    static func keys(forAngle angle: CGFloat) -> Set<Int> { Joystick.keys(forAngle: angle) }
}
