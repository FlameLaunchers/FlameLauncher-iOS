import GameController
import QuartzCore

/// 게임패드/조이스틱 → 마인크래프트 입력 변환. 안드로이드 `GamepadHandler` 이식.
///
/// 마인크래프트 자바판은 컨트롤러를 네이티브로 지원하지 않는다(바닐라가 GLFW 조이스틱
/// API 를 쓰지 않음). 그래서 패드 입력을 **키보드/마우스 이벤트로 변환**하는 게
/// 유일한 방법이고, 콘솔판·Controllable 모드도 결국 같은 일을 한다.
///
/// 매핑(콘솔판 기본 배치):
///   왼쪽 스틱 → WASD (임계값 넘으면 키 누름 — MC 이동은 원래 디지털이라 이게 맞다)
///   오른쪽 스틱 → 마우스 시점 (아날로그, 프레임마다 델타 누적)
///   RT → 좌클릭(공격/채굴)   LT → 우클릭(사용/설치)
///   A → Space  B → Shift  X → Q  Y → E
///   LB/RB → 핫바 이전/다음(휠)  L3 → Ctrl(달리기)  R3 → 휠클릭
///   Menu → ESC   Options → Tab   D-pad → 방향키
///
/// iOS 는 GameController 프레임워크가 이미 디바운스·데드존·핫플러그를 다 해주므로
/// 안드로이드판의 MotionEvent 축 파싱 코드는 통째로 사라졌다.
@MainActor
final class GamepadHandler {
    private let sendKey: (Int, Int) -> Void
    private let sendMouseButton: (Int, Int) -> Void
    private let sendScroll: (Double, Double) -> Void
    private let moveCursorBy: (Double, Double) -> Void

    /// 스틱이 이 값을 넘어야 이동키를 누른다.
    private let moveThreshold: Float = 0.5
    /// 트리거가 이 값을 넘으면 눌린 것으로 본다.
    private let triggerThreshold: Float = 0.5
    /// 오른쪽 스틱 최대 기울기에서의 시점 회전 속도(포인트/초).
    private let lookSpeed: Double = 900

    /// 연결된 패드가 하나라도 있는지. 표시용일 뿐, 이 값으로 화면 버튼을 숨기지 않는다
    /// (오탐 한 번에 컨트롤러가 영영 사라지는 문제 때문에 안드로이드가 이미 폐기한 방식).
    private(set) var isConnected = false

    private var displayLink: CADisplayLink?
    private var lookX: Float = 0
    private var lookY: Float = 0
    /// 눌림 상태를 기억해 같은 키를 매 프레임 재전송하지 않는다(에지 검출).
    private var held: Set<Int> = []
    private var heldMouse: Set<Int> = []
    private var observers: [NSObjectProtocol] = []

    init(
        sendKey: @escaping (Int, Int) -> Void,
        sendMouseButton: @escaping (Int, Int) -> Void,
        sendScroll: @escaping (Double, Double) -> Void,
        moveCursorBy: @escaping (Double, Double) -> Void
    ) {
        self.sendKey = sendKey
        self.sendMouseButton = sendMouseButton
        self.sendScroll = sendScroll
        self.moveCursorBy = moveCursorBy
    }

    func start() {
        guard displayLink == nil else { return }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { self?.attach(n.object as? GCController) }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshConnection() }
            },
        ]
        GCController.controllers().forEach(attach)
        refreshConnection()

        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] dt in self?.pump(dt) },
                                 selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// 펌프 정지 + 눌려 있던 입력 전부 해제.
    /// 이걸 안 하면 패드를 뽑거나 앱이 백그라운드로 갈 때 W 가 눌린 채로 남아
    /// 캐릭터가 계속 앞으로 걸어간다.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        lookX = 0; lookY = 0
        held.forEach { sendKey($0, GlfwKeys.release) }
        held.removeAll()
        heldMouse.forEach { sendMouseButton($0, GlfwKeys.release) }
        heldMouse.removeAll()
    }

    private func refreshConnection() {
        isConnected = !GCController.controllers().isEmpty
    }

    private func attach(_ controller: GCController?) {
        guard let pad = controller?.extendedGamepad else { return }
        refreshConnection()

        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            // 이동은 디지털 — 임계값을 넘는 방향의 키만 누른다.
            edgeKey(87, x: y > moveThreshold)            // W
            edgeKey(83, x: y < -moveThreshold)           // S
            edgeKey(65, x: x < -moveThreshold)           // A
            edgeKey(68, x: x > moveThreshold)            // D
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.lookX = x
            self?.lookY = -y   // 화면 y 는 아래가 +
        }
        pad.rightTrigger.valueChangedHandler = { [weak self] _, v, _ in
            self?.edgeMouse(GlfwKeys.mouseLeft, v > self!.triggerThreshold)
        }
        pad.leftTrigger.valueChangedHandler = { [weak self] _, v, _ in
            self?.edgeMouse(GlfwKeys.mouseRight, v > self!.triggerThreshold)
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(GlfwKeys.space, x: p) }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(GlfwKeys.leftShift, x: p) }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(81, x: p) }   // Q 버리기
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(69, x: p) }   // E 인벤토리
        pad.leftShoulder.pressedChangedHandler = { [weak self] _, _, p in if p { self?.sendScroll(0, 1) } }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, p in if p { self?.sendScroll(0, -1) } }
        pad.leftThumbstickButton?.pressedChangedHandler = { [weak self] _, _, p in
            self?.edgeKey(GlfwKeys.leftControl, x: p)
        }
        pad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, p in
            self?.edgeMouse(GlfwKeys.mouseMiddle, p)
        }
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(GlfwKeys.escape, x: p) }
        pad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(GlfwKeys.tab, x: p) }
        pad.dpad.up.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(GlfwKeys.up, x: p) }
        pad.dpad.down.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(GlfwKeys.down, x: p) }
        pad.dpad.left.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(GlfwKeys.left, x: p) }
        pad.dpad.right.pressedChangedHandler = { [weak self] _, _, p in self?.edgeKey(GlfwKeys.right, x: p) }
    }

    private func edgeKey(_ code: Int, x pressed: Bool) {
        if pressed, !held.contains(code) {
            held.insert(code); sendKey(code, GlfwKeys.press)
        } else if !pressed, held.contains(code) {
            held.remove(code); sendKey(code, GlfwKeys.release)
        }
    }

    private func edgeMouse(_ button: Int, _ pressed: Bool) {
        if pressed, !heldMouse.contains(button) {
            heldMouse.insert(button); sendMouseButton(button, GlfwKeys.press)
        } else if !pressed, heldMouse.contains(button) {
            heldMouse.remove(button); sendMouseButton(button, GlfwKeys.release)
        }
    }

    private func pump(_ dt: CFTimeInterval) {
        guard lookX != 0 || lookY != 0 else { return }
        // dt 상한 — 앱이 잠깐 멈췄다 돌아왔을 때 시점이 확 튀는 것 방지.
        let step = min(max(dt, 0), 1.0 / 20.0)
        moveCursorBy(Double(lookX) * lookSpeed * step, Double(lookY) * lookSpeed * step)
    }
}

/// CADisplayLink 는 target 을 strong 으로 잡으므로 프록시를 하나 둔다.
private final class DisplayLinkProxy: NSObject {
    private let handler: (CFTimeInterval) -> Void
    private var last: CFTimeInterval = 0

    init(_ handler: @escaping (CFTimeInterval) -> Void) { self.handler = handler }

    @objc func tick(_ link: CADisplayLink) {
        let dt = last == 0 ? 0 : link.timestamp - last
        last = link.timestamp
        handler(dt)
    }
}
