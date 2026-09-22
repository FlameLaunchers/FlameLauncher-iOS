import UIKit
import SwiftUI

/// UIKit 진입점. SwiftUI 화면은 `UIHostingController` 로 얹는다.
///
/// SwiftUI 의 `App` 라이프사이클을 쓰지 않는 이유는 `main.m` 머리말 참고 —
/// JLI 가 프로세스 진입점을 다시 호출하기 때문에, 진입점은 우리가 직접 쥐고 있어야 한다.
/// (PojavLauncher / Amethyst 도 같은 이유로 UIKit 구조다)
@objc(FlameAppDelegate)
final class FlameAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    /// 앱 전체를 가로로 고정한다. 화면 버튼 배치가 전부 가로 기준이라
    /// 세로에서는 겹치고, 게임도 가로로만 띄운다.
    static var orientationMask: UIInterfaceOrientationMask = .landscape

    private let launcher = LauncherModel()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let root = RootView()
            .environment(launcher)
            .environment(AuthStore.shared)
            .preferredColorScheme(.dark)
            .tint(FlameColor.primary)

        let host = FlameHostingController(rootView: root)
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = UIColor(FlameColor.bgDark)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        // ⚠️ 이 시점의 UIScreen.main.bounds 는 아직 세로일 수 있다. 씬에 붙여 기하를
        //    따라가게 한다 — 안 그러면 세로 프레임이 그대로 굳는다(OrientationLock 참고).
        OrientationLock.attachToScene(window)
        OrientationLock.watch(window)

        Task { @MainActor in
            await AuthStore.shared.restore()
            await launcher.loadVersions()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }

    /// 앱이 앞으로 돌아올 때마다 방향을 다시 건다.
    ///
    /// ⚠️ 플래그(`orientationMask`)만 들고 있으면 iOS 가 **다시 물어볼 때까지** 그대로다.
    ///    JIT 도구(StikDebug)나 공유 시트를 다녀오면 돌아온 씬이 세로로 잡혀 있는 경우가
    ///    있는데, 그땐 아무도 다시 묻지 않아서 세로인 채로 남는다 — 사용자가 겪던
    ///    "중간중간 세로로 돌아간다"가 이것이다. 활성화될 때마다 한 번 더 요청해 창을 없앤다.
    func applicationDidBecomeActive(_ application: UIApplication) {
        OrientationLock.reassert()
        // 창이 씬 기하를 놓쳤으면 여기서 되돌린다. 씬은 앱이 백그라운드를
        // 다녀올 때 갱신되는데, 씬에 안 붙은 창은 그걸 따라가지 못한다.
        OrientationLock.attachToScene(window)
    }
}


/// 홈 인디케이터를 숨기는 호스팅 컨트롤러.
///
/// 인디케이터가 숨겨져 있으면 iOS 는 **먼저 한 번 쓸어야 인디케이터를 띄운다** —
/// 즉 바닥에서 시작하는 드래그(인벤토리 맨 아랫줄)가 한 단계 보호된다.
/// 예전에는 같은 목적으로 `preferredScreenEdgesDeferringSystemGestures` 를 켰는데,
/// 그건 인디케이터를 **계속 띄워 두는** 설정이라 오히려 역효과였다.
final class FlameHostingController<Content: View>: UIHostingController<Content> {
    // ⚠️ 가장자리 제스처 지연(`preferredScreenEdgesDeferringSystemGestures`)은 **걸지
    //    않는다**. 걸어 두면 iOS 가 "여기는 한 번 더 쓸어야 나갑니다" 를 알리려고 홈
    //    인디케이터를 계속 띄워 두기 때문에, 자동 숨김이 아예 오지 않는다 —
    //    `prefersHomeIndicatorAutoHidden` 과 정면으로 싸우는 설정이다.
    //    (SwiftUI 상속값이 0xa = left|right 라 아래에서 비운다. 자세한 사정은 GameView)
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // 앱 전체 가로 고정 — 뿌리 컨트롤러도 스스로 가로만 답한다(마스크·Info.plist 와 같은 값).
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    // ⚠️ 상속하면 `.left | .right`(0xa) 가 나온다 — SwiftUI 기본값이다.
    //    하나라도 지연하면 인디케이터가 안 사라지므로 비운다(GameView 주석 참고).
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [] }

    // 자식(SwiftUI 콘텐츠)에게 위임되면 위 값들이 무시된다. 우리가 답한다.
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
}
