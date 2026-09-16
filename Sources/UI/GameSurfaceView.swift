import SwiftUI
import UIKit

/// 게임이 그려지는 표면 + 터치 입력. 안드로이드 `MinecraftSurface`(SurfaceView) 이식.
///
/// 터치 규칙도 그대로 옮겼다:
///  - 인게임(grab) 중 핫바 영역 탭 → 슬롯 선택 전용 (카메라/클릭으로 넘기지 않음)
///  - 20pt 이상 끌면 카메라 회전, 그 전에 떼면 좌클릭
///  - 0.5초 누르면 채굴(좌클릭 유지), 전투 모드면 우클릭
///  - **첫 손가락만** 카메라/클릭을 담당한다. 둘째 손가락이 들어와도 좌표가 튀지 않는다.
struct GameSurface: UIViewRepresentable {
    let runtime: JavaRuntime
    let settings: JvmSettings
    let renderer: Renderer
    @Binding var guiScale: Int
    /// 서피스 크기가 정해지면(첫 레이아웃) 알려준다 — 여기서 JVM 부팅을 시작한다.
    let onReady: (CALayer, CGSize) -> Void
    /// 만들어진 뷰 자체를 넘긴다. 전투 모드 전환과 게임패드 시점 이동이
    /// 이 뷰의 메서드를 직접 불러야 하기 때문이다.
    let onCreate: (MinecraftSurfaceView) -> Void

    func makeUIView(context: Context) -> MinecraftSurfaceView {
        // ⚠️ 서피스는 프로세스당 하나뿐이다.
        //    JVM 은 한 번만 띄울 수 있고(JLI_Launch), 그 EGL 서피스는 **이 레이어**에
        //    묶여 있다. 게임 화면을 닫았다 다시 열 때 새 뷰를 만들면 렌더 스레드가
        //    사라진 레이어를 붙들고 죽는다 — 그래서 만들어둔 걸 그대로 재사용한다.
        if let existing = GameSurfaceHolder.view {
            existing.runtime = runtime
            existing.sensitivity = settings.mouseSensitivity
            existing.applyResolutionScale(settings.resolutionScale)
            DispatchQueue.main.async { onCreate(existing) }
            return existing
        }
        // ⚠️ 레이어 종류가 렌더러에 따라 다르다. EGL(ANGLE/GL4ES)은 CAMetalLayer 를 네이티브
        //    윈도우로 받고, OSMesa(Zink)는 프레임버퍼를 CGImage 로 올리므로 일반 CALayer 여야 한다.
        //    UIView 는 layerClass 가 정적이라 생성 시점에 결정해야 한다.
        let view = renderer.usesMetalLayer ? MetalSurfaceView() : MinecraftSurfaceView()
        view.runtime = runtime
        view.sensitivity = settings.mouseSensitivity
        view.resolutionScale = settings.resolutionScale
        view.onReady = onReady
        // ⚠️ 뷰 계층을 뒤져서 찾는 방식은 생성 시점이 어긋나면 영영 못 찾는다 —
        //    실제로 전투 모드 토글과 게임패드 시점 이동이 통째로 먹통이었다.
        //    만드는 쪽에서 바로 넘긴다.
        GameSurfaceHolder.view = view
        DispatchQueue.main.async { onCreate(view) }
        return view
    }

    func updateUIView(_ view: MinecraftSurfaceView, context: Context) {
        view.guiScale = guiScale
        view.sensitivity = settings.mouseSensitivity
        view.applyResolutionScale(settings.resolutionScale)
    }
}

/// 프로세스에 단 하나뿐인 게임 서피스를 붙잡아 둔다.
/// SwiftUI 가 화면에서 내려도 레이어가 살아 있어야 JVM 렌더 스레드가 안전하다.
enum GameSurfaceHolder {
    static var view: MinecraftSurfaceView?
}

/// OSMesa(Zink) 경로용 — 일반 CALayer.
class MinecraftSurfaceView: UIView {
    var runtime: JavaRuntime = StubJavaRuntime()
    var onReady: ((CALayer, CGSize) -> Void)?
    var sensitivity: Double = 1.5
    var resolutionScale: Double = 1
    var guiScale = 0
    /// 전투 모드: 길게 누르면 좌클릭(채굴) 대신 우클릭(사용/공격)을 보낸다.
    var combatMode = false

    /// 탭·길게누르기가 보낼 마우스 버튼.
    ///
    /// ⚠️ 전투 모드(우클릭)는 **인게임에서만** 쓴다. 메뉴·인벤토리에서도 우클릭을 보내면
    ///    "설정" 같은 GUI 버튼이 눌리지 않는다 — 마인크래프트 GUI 는 좌클릭으로 동작한다.
    private var tapButton: Int { TouchButton.tap(combatMode: combatMode, grabbing: runtime.isGrabbing) }
    private var holdButton: Int { TouchButton.hold(combatMode: combatMode, grabbing: runtime.isGrabbing) }

    /// 메뉴/인벤토리에서 버튼을 누른 채 끌고 있는 중인지.
    /// (작업대에 재료를 옮기는 것처럼 GUI 드래그는 누름 → 이동 → 뗌 이 필요하다)
    private var guiDragging = false

    // ── 터치 상태 (안드로이드 MinecraftSurface 의 전역 변수들과 대응) ──
    private static let dragSlop: CGFloat = 20
    private static let longPressDelay: TimeInterval = 0.5

    private var activeTouch: UITouch?
    private var downPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var isDragging = false
    private var isLongPress = false
    /// 길게 눌러 붙잡고 있는 버튼. 뗄 때 **이 값으로** 떼야 한다(모드가 바뀌어도 안전).
    private var heldButton = GlfwKeys.mouseLeft
    private var isHotbarTouch = false
    private var longPressWork: DispatchWorkItem?
    private var didReport = false
    /// 게임 창 좌표계에서의 커서 위치. 메뉴/인벤토리 클릭에 쓴다.
    private var cursor: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        layer.isOpaque = true
        layer.drawsAsynchronously = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 프레임버퍼 크기(픽셀). 해상도 배율이 적용된 값.
    private(set) var drawableSize: CGSize = .zero

    /// 렌더 해상도 배율을 바꾼다.
    ///
    /// ⚠️ 값만 바꿔서는 아무 일도 안 일어난다 — 프레임버퍼는 `layoutSubviews` 에서
    ///    만들어지는데, 화면 크기가 그대로면 SwiftUI 는 레이아웃을 다시 돌리지 않는다.
    ///    그래서 직접 요청해야 설정이 실제로 먹는다(설정에서 바꿔도 그대로였던 이유).
    func applyResolutionScale(_ scale: Double) {
        guard scale != resolutionScale else { return }
        resolutionScale = scale
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 렌더 해상도 배율 적용 — 낮추면 프레임버퍼가 작아져 FPS가 오른다.
        let scale = UIScreen.main.nativeScale * resolutionScale
        layer.contentsScale = scale
        drawableSize = CGSize(width: (bounds.width * scale).rounded(.down),
                              height: (bounds.height * scale).rounded(.down))
        configureLayer(scale: scale)

        runtime.setScreenSize(Int(drawableSize.width), Int(drawableSize.height))
        // 설정 화면이 "이 배율이면 HUD 가 몇 배" 를 정확히 보여주려면 게임이 실제로
        // 쓰는 높이가 필요하다(안전영역 때문에 화면 크기와 다르다). 여기가 유일하게
        // 그 값을 아는 지점이다.
        JvmSettings.lastFullFramebufferHeight = Int(bounds.height * UIScreen.main.nativeScale)
        cursor = CGPoint(x: bounds.midX, y: bounds.midY)

        // ⚠️ 회전이 **끝난 뒤** 크기로만 JVM 을 띄운다.
        //    GameView 는 .lockOrientation(.landscape) 지만 그건 onAppear 에서 걸리고,
        //    첫 layoutSubviews 는 아직 세로일 때 돈다. 그 크기로 보고하면
        //    -Dglfw.windowSize / -Dcacio.managed.screensize 가 세로(1179x2556)로 굳고,
        //    세로 서피스가 가로 레이어(2556x1179)에 1:1 로 붙어서 화면 왼쪽 아래
        //    1179x1179 정사각형만 그려진다(실제로 그렇게 나왔다).
        if !didReport, bounds.width >= bounds.height {
            didReport = true
            onReady?(layer, drawableSize)
        }
    }

    /// 레이어 종류에 따른 추가 설정. 서브클래스가 덮어쓴다.
    func configureLayer(scale: CGFloat) {}

    // MARK: - 좌표 변환

    /// 뷰 좌표 → 게임 창 좌표. 해상도 배율이 100% 미만이면 프레임버퍼가 화면보다
    /// 작으므로 클릭 위치를 같은 비율로 줄여야 UI 히트가 맞는다.
    /// (인게임 카메라는 델타 기반이라 변환하지 않는다 — 감도가 배율에 끌려가면 안 된다.)
    private func toGame(_ point: CGPoint) -> CGPoint {
        let sx = bounds.width > 0 ? drawableSize.width / bounds.width : 1
        let sy = bounds.height > 0 ? drawableSize.height / bounds.height : 1
        return CGPoint(x: point.x * sx, y: point.y * sy)
    }

    // MARK: - 핫바

    /// 현재 화면 기준 핫바의 사각형. 마인크래프트와 같은 규칙:
    /// slotSize = guiScale*20(GUI 단위), 핫바 너비 = slotSize*9, 화면 하단 중앙.
    ///
    /// ⚠️ 예전에는 이 안에서 스케일을 어림했는데 **단위를 틀렸다** — 뷰 좌표(pt)를
    ///    320x240 으로 나눴지만 마인크래프트는 **프레임버퍼 px** 로 나눈다.
    ///    아이폰 15 에서 `min(852/320, 373/240) = 1` 이 나와 실제 스케일 2 의 절반짜리
    ///    영역이 됐고, 그래서 "핫바 터치 영역 크기" 수동 설정이 따로 있어야 했다.
    ///    이제 `guiScale` 은 런처가 계산해 넘기는 **실제 값**이고, 여기서는 좌표만 옮긴다.
    func hotbarRect() -> CGRect? {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0, guiScale > 0, drawableSize.height > 0 else { return nil }

        // 프레임버퍼 px → 뷰 pt. 해상도 배율이 100% 미만이면 둘이 다르다.
        let toPoints = h / drawableSize.height
        let slot = CGFloat(guiScale * 20) * toPoints
        let total = slot * 9
        guard total > 0, total <= w else { return nil }
        return CGRect(x: (w - total) / 2, y: h - slot, width: total, height: slot)
    }

    /// 마인크래프트는 1~9 키로 슬롯을 직접 선택한다 → GLFW_KEY_1(49) + index.
    private func selectHotbarSlot(_ index: Int) {
        guard (0...8).contains(index) else { return }
        runtime.sendKey(49 + index, action: GlfwKeys.press, mods: 0)
        runtime.sendKey(49 + index, action: GlfwKeys.release, mods: 0)
    }

    // MARK: - 터치

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 첫 손가락만 카메라/클릭을 담당한다. 이미 활성 포인터가 있으면 무시.
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        downPoint = touch.location(in: self)
        lastPoint = downPoint
        isDragging = false
        isLongPress = false
        isHotbarTouch = false

        // 인게임 + 핫바 영역 → 슬롯 선택 전용. 카메라/클릭으로 넘기지 않는다.
        if runtime.isGrabbing, let rect = hotbarRect(), rect.contains(downPoint) {
            let index = Int((downPoint.x - rect.minX) / (rect.width / 9))
            selectHotbarSlot(min(max(index, 0), 8))
            isHotbarTouch = true
            return
        }

        // 메뉴/인벤토리(grab 아님)에서는 손가락 위치가 곧 커서 위치다.
        if !runtime.isGrabbing {
            cursor = downPoint
            let p = toGame(downPoint)
            runtime.sendCursorPos(p.x, p.y, relative: false)
        }

        // 길게 누르기(채굴)는 인게임에서만 의미가 있다. 메뉴에서 걸리면 드래그와 엉킨다.
        if runtime.isGrabbing { scheduleLongPress() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let point = touch.location(in: self)
        defer { lastPoint = point }
        guard !isHotbarTouch else { return }

        if !isDragging {
            let moved = hypot(point.x - downPoint.x, point.y - downPoint.y)
            guard moved > Self.dragSlop else { return }
            isDragging = true
            cancelLongPress()
        }

        if runtime.isGrabbing {
            // 인게임: 델타로 시점 회전. 감도는 설정값 그대로.
            let dx = (point.x - lastPoint.x) * sensitivity
            let dy = (point.y - lastPoint.y) * sensitivity
            moveLookBy(dx, dy)
        } else {
            // 메뉴: 절대 좌표로 커서 이동.
            // ⚠️ 끌기 시작 시 **버튼을 누른 채로** 옮겨야 아이템을 집어 옮길 수 있다.
            //    (예전엔 끌면 touchesEnded 가 클릭을 통째로 취소해서 작업대에 재료를
            //     놓을 수 없었다)
            if !guiDragging {
                guiDragging = true
                runtime.sendMouseButton(GlfwKeys.mouseLeft, action: GlfwKeys.press)
            }
            cursor = point
            let p = toGame(point)
            runtime.sendCursorPos(p.x, p.y, relative: false)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelLongPress()
        defer { activeTouch = nil }
        guard !isHotbarTouch else { return }

        if guiDragging {
            runtime.sendMouseButton(GlfwKeys.mouseLeft, action: GlfwKeys.release)
            guiDragging = false
            return
        }

        if isLongPress {
            // ⚠️ 누를 때 쓴 버튼을 그대로 떼야 한다. tapButton 을 다시 계산하면 그 사이
            //    전투 모드가 바뀌었을 때 **다른 버튼을 떼서** 원래 버튼이 눌린 채로 남는다.
            runtime.sendMouseButton(heldButton, action: GlfwKeys.release)
            isLongPress = false
            return
        }

        guard !isDragging else { return }
        // 끌지 않고 뗐다 = 탭.
        //
        // ⚠️ 누르고 **같은 프레임에** 떼면 게임이 통째로 못 본다. 마인크래프트는 틱마다
        //    한 번 입력을 읽기 때문에(50ms), 그 사이에 눌렀다 뗀 건 없던 일이 된다.
        //    안드로이드도 같은 이유로 50ms 를 두고 뗀다.
        let button = tapButton
        runtime.sendMouseButton(button, action: GlfwKeys.press)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [runtime] in
            runtime.sendMouseButton(button, action: GlfwKeys.release)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()
        // 끌던 중 취소되면 버튼이 눌린 채로 남는다 — 반드시 떼준다.
        if guiDragging {
            runtime.sendMouseButton(GlfwKeys.mouseLeft, action: GlfwKeys.release)
            guiDragging = false
        }
        if isLongPress {
            runtime.sendMouseButton(heldButton, action: GlfwKeys.release)
        }
        activeTouch = nil
        isLongPress = false
        isDragging = false
        isHotbarTouch = false
    }

    /// 화면 버튼/게임패드/드래그에서 공통으로 쓰는 시점 이동.
    /// 인게임(grab)에서는 **상대 델타**로 보낸다 — 절대좌표로 보내면 화면 가장자리에서
    /// 좌표가 더 안 변해 시점 회전이 멈춘다(데스크톱 마우스와 완전히 다른 동작).
    func moveLookBy(_ dx: Double, _ dy: Double) {
        if runtime.isGrabbing {
            runtime.sendCursorPos(dx, dy, relative: true)
        } else {
            cursor.x += dx
            cursor.y += dy
            let p = toGame(cursor)
            runtime.sendCursorPos(p.x, p.y, relative: false)
        }
    }

    private func scheduleLongPress() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isDragging, !isHotbarTouch else { return }
            isLongPress = true
            heldButton = holdButton
            runtime.sendMouseButton(heldButton, action: GlfwKeys.press)
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressDelay, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    // MARK: - SDL3 (26.3+)

    /// 26.3+ 가 SDL 로 만든 게임 화면을 이 서피스 **안으로** 들인다.
    /// Vulkan 서피스(Metal 뷰)까지 들였으면 true — 곧 첫 프레임이 나온다.
    ///
    /// ⚠️ SDL 의 uikit 백엔드는 UIWindow 를 새로 만들어 `makeKeyAndVisible` 한다
    ///    (UIKit_ShowWindow). 그 창이 앱 창 위를 덮어서 화면 버튼·부팅 오버레이가 전부
    ///    가려졌다 — "로딩 타이틀은 뜨는데 가상 키패드가 안 뜬다" 가 이것이다.
    ///    SDL 창의 루트 뷰를 여기 맨 아래로 옮기고 SDL 창은 숨긴다. 터치는 핫바·길게 누르기·
    ///    감도 규칙을 가진 이 뷰가 계속 받아야 하므로 옮긴 뷰는 터치를 끈다.
    ///
    /// ⚠️ 한 번으로 안 끝난다. SDL 은 Vulkan 서피스를 만들 때 새 Metal 뷰를 `rootViewController`
    ///    재지정으로 **자기 창에 다시 꽂는다**(-[SDL_uikitview setSDLWindow:]). 그래서 GameView
    ///    폴링이 매번 부른다 — 이미 들였으면 비교 몇 번으로 끝난다.
    func adoptSDLWindow() -> Bool {
        guard let host = window,
              let sdl = host.windowScene?.windows.first(where: {
                  $0 !== host && $0.rootViewController.map { NSStringFromClass(type(of: $0)) }
                      == "SDL_uikitviewcontroller"
              }),
              let content = sdl.rootViewController?.view
        else { return false }

        if content.superview !== self {
            content.frame = bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.isUserInteractionEnabled = false
            insertSubview(content, at: 0)
        }
        if !sdl.isHidden {
            sdl.isHidden = true
            host.makeKey()
        }
        return content.layer is CAMetalLayer
    }

    // MARK: - 하드웨어 키보드

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, action: GlfwKeys.press) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, action: GlfwKeys.release) { super.pressesEnded(presses, with: event) }
    }

    private func handle(_ presses: Set<UIPress>, action: Int) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key, let glfw = GlfwKeys.fromHID(key.keyCode) else { continue }
            runtime.sendKey(glfw, action: action, mods: GlfwKeys.mods(from: key.modifierFlags))
            // 문자 입력(채팅)은 키 이벤트와 별개로 char 콜백도 보내야 한다.
            if action == GlfwKeys.press,
               let scalar = key.charactersIgnoringModifiers.unicodeScalars.first,
               scalar.value >= 32, scalar.value != 127 {
                let shifted = key.modifierFlags.contains(.shift)
                    ? key.characters.unicodeScalars.first ?? scalar
                    : scalar
                runtime.sendChar(shifted.value)
            }
            handled = true
        }
        return handled
    }
}

/// EGL(ANGLE / GL4ES) 경로용 — CAMetalLayer 를 네이티브 윈도우로 넘긴다.
final class MetalSurfaceView: MinecraftSurfaceView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    override func configureLayer(scale: CGFloat) {
        guard let metal = layer as? CAMetalLayer else { return }
        metal.drawableSize = drawableSize
        // ANGLE 이 자기 텍스처로 읽어가므로 프레임버퍼 전용으로 두면 안 된다.
        metal.framebufferOnly = false
    }
}
