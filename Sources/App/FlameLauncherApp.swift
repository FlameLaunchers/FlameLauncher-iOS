import SwiftUI

// 진입점은 `Sources/Natives/main.m` + `FlameAppDelegate` 다.
// SwiftUI 의 `@main` 을 쓰지 않는 이유는 main.m 머리말 참고
// (JLI 가 프로세스 진입점을 다시 호출한다).

/// 안드로이드는 화면마다 Activity 였지만(MainActivity / SettingsActivity / ...),
/// iOS 는 NavigationStack 하나로 충분하다 — Intent·결과 콜백·백스택 관리가 통째로 사라진다.
struct RootView: View {
    @Environment(LauncherModel.self) private var launcher

    var body: some View {
        @Bindable var launcher = launcher

        NavigationStack(path: $launcher.path) {
            MainView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .settings:
                        SettingsView()
                    case .instanceSettings(let id):
                        InstanceSettingsView(instanceId: id)
                    case .contentBrowser:
                        ContentBrowserView()
                    case .terracotta:
                        TerracottaView()
                    case .contentDetail(let item):
                        ContentDetailView(item: item)
                    case .keyLayout:
                        KeyLayoutEditorView()
                    case .crashReport(let id):
                        CrashReportView(instanceId: id)
                    }
                }
        }
        .fullScreenCover(item: $launcher.runningInstance) { meta in
                // ⚠️ 시트/커버는 SwiftUI 가 **별도의 PresentationHostingController** 로 띄운다.
                //    우리는 환경을 루트 UIHostingController 바깥에서 걸기 때문에(AppDelegate),
                //    iOS 는 알아서 복사해 주지만 맥('Designed for iPad')은 안 해준다 —
                //    그쪽에서 @Environment(LauncherModel.self) 를 읽는 순간
                //    "No Observable object of type LauncherModel found" 로 죽는다.
                //    모달 경계에서는 직접 넣어준다.
            GameView(meta: meta)
                .environment(launcher)
                .environment(AuthStore.shared)
        }
        // JIT 은 실행 시점이 아니라 **여기서** 미리 확보한다. 설치가 끝나자마자 실행으로
        // 이어지는 흐름(installAndPlay) 한가운데서 StikDebug 로 튀어나가지 않게 하려는 것이다.
        .task {
            await JITStatus.shared.prepareAtLaunch()
            // JIT 을 확보한 **다음에** 이어서 실행한다. 순서가 바뀌면 게임 화면이
            // JIT 게이트에 걸려 멈춰 선다(부팅 중 코드 캐시를 못 잡아 죽기 때문).
            launcher.resumePendingLaunchIfNeeded()
        }
    }
}

enum Route: Hashable {
    case settings
    case instanceSettings(String)
    case contentBrowser
    case contentDetail(ContentItem)
    case keyLayout
    case terracotta
    case crashReport(String)
}
