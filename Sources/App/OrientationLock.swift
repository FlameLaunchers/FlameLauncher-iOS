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
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            // ⚠️ rootViewController 만 갱신하면 안 된다. 시트나 fullScreenCover 가 떠 있으면
            //    **그 위에 올라온 컨트롤러**가 방향을 결정한다 — 게임 화면이 정확히 그 경우다.
            for window in scene.windows {
                var controller = window.rootViewController
                while let presented = controller?.presentedViewController {
                    controller = presented
                }
                controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
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
