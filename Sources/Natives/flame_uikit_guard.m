//
//  flame_uikit_guard.m — JRE 가 앱을 다시 띄우려는 것을 막는다.
//
//  증상: `JLI_Launch` 직후 SwiftUI 가 두 번째로 초기화되며 죽는다.
//        "SwiftUI/AppGraph.swift:26: Fatal error: AppGraph.shared may only be set once!"
//
//  배경: Amethyst / PojavLauncher iOS 의 JRE 는 "JRE 가 프로세스의 주인" 인 구조를 전제로
//        빌드돼 있다. 그래서 JLI 가 호출 스레드를 이벤트 루프에 묶는 경로에서 UIKit 진입까지
//        건드릴 수 있다. 우리처럼 SwiftUI 앱이 **이미 떠 있는** 상태에서 그게 돌면
//        UIApplicationMain 이 두 번 불리고, SwiftUI 는 그걸 치명적 오류로 처리한다.
//
//  대응: UIApplicationMain 을 fishhook 으로 가로채 **두 번째 호출을 삼킨다.**
//        원래 이 함수는 반환하지 않으므로(앱이 끝날 때까지 이벤트 루프), 그냥 리턴하면
//        호출자가 정상 종료로 오해한다. 그래서 그 스레드를 영원히 재운다.
//
//  ⚠️ 진짜 원인을 못 찾은 채 덮는 게 아니라, 첫 호출에서 스택을 남겨 원인을 기록한다.
//     로그에 찍힌 호출자를 보고 상류(JRE 빌드) 쪽을 고칠 수 있으면 그게 낫다.
//
#import <UIKit/UIKit.h>
#include <stdatomic.h>
#include <unistd.h>
#include <limits.h>

#include "fishhook/fishhook.h"

static int (*orig_UIApplicationMain)(int argc, char *_Nullable argv[_Nonnull],
                                     NSString *_Nullable principalClassName,
                                     NSString *_Nullable delegateClassName);

static atomic_int flameUIApplicationMainCount;

static int flame_UIApplicationMain(int argc, char *argv[],
                                   NSString *principalClassName,
                                   NSString *delegateClassName) {
    int previous = atomic_fetch_add(&flameUIApplicationMainCount, 1);
    if (previous == 0) {
        return orig_UIApplicationMain(argc, argv, principalClassName, delegateClassName);
    }

    // 두 번째 이후 — 누가 불렀는지 남기고 이 스레드를 멈춘다.
    NSLog(@"[FlameLauncher] ⚠️ UIApplicationMain 재호출을 차단했습니다 (%d번째)\n"
          @"  호출 스택:\n%@",
          previous + 1, [NSThread.callStackSymbols componentsJoinedByString:@"\n"]);

    // 반환하면 호출자가 "앱이 끝났다" 로 해석해 정리 절차를 밟는다 — 그대로 재운다.
    while (1) sleep(UINT_MAX);
    return 0;
}

__attribute__((constructor))
static void flame_installUIKitGuard(void) {
    struct rebinding r = {"UIApplicationMain", (void *)flame_UIApplicationMain,
                          (void **)&orig_UIApplicationMain};
    if (rebind_symbols(&r, 1) != 0) {
        NSLog(@"[FlameLauncher] UIApplicationMain 후킹 실패 — 재호출 방어가 없습니다");
    }
}
