//
//  main.m — 프로세스 진입점.
//
//  PojavLauncher / Amethyst 의 `Natives/main.m` 과 같은 구조다. SwiftUI 의 `@main` 을 쓰지
//  않고 진짜 C `main()` 을 두는 이유는 하나다:
//
//  ⚠️ Darwin JLI 는 `JLI_Launch` 안에서 `apple_main` 이라는 새 pthread 를 만들고,
//     거기서 `dlsym(RTLD_DEFAULT, "main")` 으로 찾은 **호스트 실행 파일의 main 을 다시 호출**한다.
//     JVM 은 그 스레드에서 돌아야 하므로 이건 정상 설계다.
//
//     SwiftUI 의 `@main` 을 쓰면 그 재진입이 App 의 진입점으로 들어가 앱 전체가 두 번
//     초기화되고 "AppGraph.shared may only be set once" 로 죽는다. C main 을 직접 두면
//     상류처럼 `if (재진입) return JLI 계속` 한 줄로 끝난다.
//
#import <UIKit/UIKit.h>

#include "FlameNative.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // JLI 가 apple_main 에서 우리를 다시 부른 경우 — 이 스레드에서 JVM 을 이어 실행한다.
        // (상류의 `if (pJLI_Launch) return pJLI_Launch(...)` 와 같은 자리)
        if (FlameNativeContinueJVM()) {
            return 0;   // 사실 여기까지 오지 않는다
        }

        return UIApplicationMain(argc, argv, nil, @"FlameAppDelegate");
    }
}
