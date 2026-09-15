import SwiftUI
import UIKit

/// 앱을 가로로 고정한다.
///
/// 마인크래프트 자바판은 데스크톱 가로 화면 게임이고, 화면 버튼 기본 배치(`KeyLayoutStore`)도
/// 안드로이드의 **가로 프리셋** 좌표를 그대로 쓴다. 세로로 두면 x 간격 0.08 이 실제로는
/// 32pt 밖에 안 돼서 48pt 버튼들이 서로 겹치고 화면 밖으로 밀려난다.
/// 런처 화면도 2:4 분할이라 세로에서는 왼쪽이 종잇장이 된다.
///
/// (안드로이드는 방향을 안 잠그는 대신 GameControllerView 가 겹침을 감지해 프리셋으로
///  재배치했지만, 그 프리셋 자체가 가로용이라 세로에서는 결국 겹친다. iOS 는 씬 단위로
///  방향을 제한할 수 있으니 원인을 없애는 쪽이 짧다.)
///
/// 실제 마스크는 `FlameAppDelegate.orientationMask` 가 들고 있다.
extension View {
    /// 이 화면이 떠 있는 동안만 방향을 [mask] 로 제한한다.
    func lockOrientation(_ mask: UIInterfaceOrientationMask) -> some View {
        onAppear { OrientationLock.apply(mask) }
            // 앱 전체가 가로 고정이라 화면을 벗어나도 가로로 되돌린다.
            .onDisappear { OrientationLock.apply(.landscape) }
    }
}

enum OrientationLock {
    static func apply(_ mask: UIInterfaceOrientationMask) {
        FlameAppDelegate.orientationMask = mask

        // ⚠️ **모든** 윈도우 씬에 건다. 예전에는 `.first` 하나만 잡았는데, JIT 도구를
        //    다녀오거나 문서 선택기를 띄우면 씬이 하나 더 생겨서 그쪽이 안 잠겼다.
        for controller in topmostControllers() {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }

    /// 지금 화면을 실제로 지배하는 컨트롤러들.
    ///
    /// ⚠️ rootViewController 만 보면 안 된다. 시트나 fullScreenCover 가 떠 있으면
    ///    **그 위에 올라온 컨트롤러**가 방향·홈 인디케이터·제스처 지연을 결정한다 —
    ///    게임 화면이 정확히 그 경우다(fullScreenCover).
    /// ⚠️ 씬도 **전부** 훑는다. JIT 도구나 문서 선택기를 다녀오면 씬이 하나 더 생긴다.
    static func topmostControllers() -> [UIViewController] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap { window in
                var controller = window.rootViewController
                while let presented = controller?.presentedViewController {
                    controller = presented
                }
                return controller
            }
    }

    /// 창을 윈도우 씬에 붙이고 씬 기하에 맞춘다.
    ///
    /// ⚠️ 사용자가 말한 "중간중간 세로로 돌아간다"는 **인터페이스 회전이 아니다** —
    ///    Info.plist 가 가로 전용(+UIRequiresFullScreen)이라 세로는 애초에 불가능하다.
    ///    실제로 벌어지는 건 창 **프레임**이 세로 모양으로 굳는 것이다:
    ///
    ///    1. `UIWindow(frame: UIScreen.main.bounds)` 로 만든 창은 **어느 씬에도 속하지
    ///       않는다**(iOS 13+ 에서는 `windowScene` 을 줘야 한다). 씬 기하가 바뀌어도
    ///       따라가지 않는다.
    ///    2. `didFinishLaunching` 시점의 `UIScreen.main.bounds` 는 아직 세로(393x852)일
    ///       수 있다. 그 프레임이 그대로 굳으면 가로 화면 안에 세로 레이아웃이 들어앉는다.
    ///
    ///    `GameSurfaceView.layoutSubviews` 가 `bounds.width >= bounds.height` 를 확인하고
    ///    있는 것도 같은 이유다 — 세로 프레임으로 레이아웃이 실제로 돌았다는 증거다.
    ///
    ///    StikDebug 를 다녀오면 재발하던 이유: 그때만 씬 기하가 갱신되는데 창이 안 따라간다.
    static func attachToScene(_ window: UIWindow?) {
        guard let window,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState != .unattached })
        else { return }

        if window.windowScene !== scene { window.windowScene = scene }

        let bounds = scene.coordinateSpace.bounds
        guard window.frame != bounds, bounds.width > 0, bounds.height > 0 else { return }
        print("[FlameLauncher] 창을 씬 기하에 맞춥니다: "
              + "\(Int(window.frame.width))x\(Int(window.frame.height))"
              + " → \(Int(bounds.width))x\(Int(bounds.height))")
        window.frame = bounds
    }

    /// 현재 마스크를 다시 건다.
    ///
    /// 앱이 잠깐 뒤로 갔다 오면(JIT 도구·공유 시트·알림 센터) 돌아온 씬이 세로로
    /// 잡혀 있는 경우가 있다. 플래그만 들고 있으면 iOS 가 다시 물어볼 때까지 그대로다 —
    /// 활성화될 때마다 한 번 더 요청해서 그 창을 없앤다.
    static func reassert() {
        apply(FlameAppDelegate.orientationMask)
    }
}
