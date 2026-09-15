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
    }
}


/// 시스템 제스처를 최대한 미루는 호스팅 컨트롤러.
///
/// 인게임에서 화면 가장자리를 쓸면 홈으로 나가버려 인벤토리 드래그와 섞인다.
/// `preferredScreenEdgesDeferringSystemGestures` 를 켜두면 **한 번 쓸어서는**
/// 홈 제스처가 발동하지 않는다(인디케이터만 뜨고, 한 번 더 쓸어야 나간다).
/// 유튜브 전체화면이 쓰는 것과 같은 방식이고, 앱이 할 수 있는 최대치다 —
/// 홈 제스처를 완전히 막는 공개 API 는 없다(그건 '안내 접근'의 영역이다).
///
/// SwiftUI 의 `.defersSystemGestures` 만으로는 커스텀 호스팅 구조에서 전달이
/// 불안정해서, UIKit 층에서도 직접 선언한다.
final class FlameHostingController<Content: View>: UIHostingController<Content> {
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}
