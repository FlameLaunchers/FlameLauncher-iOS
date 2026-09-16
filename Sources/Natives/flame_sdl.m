// 마인크래프트 26.3+ 의 SDL3 를 이 앱 안에서 쓸 수 있는지 재는 프로브.
//
// ⚠️ 왜 재야 하는가
//    26.3 은 GLFW 를 버리고 SDL3 로 갔다(version.json 에 glfw 가 0개, lwjgl-sdl 3.4.3 이
//    들어온다). SDL3 는 GLFW 와 달리 iOS 백엔드를 원래 갖고 있지만(src/video/uikit),
//    그 백엔드는 **SDL 이 앱을 소유한다**는 전제 위에 있다 — 보통 SDL_RunApp 이
//    UIApplicationMain 을 부르고 SDL 자신의 UIApplicationDelegate 를 심는다.
//
//    우리 앱은 그렇지 않다. FlameAppDelegate 가 이미 있고, JLI 가 진입점을 다시 부르는
//    구조(main.m)라 SDL 에 진입점을 내줄 수 없다. 그래서 "이미 돌고 있는 UIApplication
//    안에서 SDL_Init(VIDEO) 가 되는가"가 나머지 설계를 전부 가른다:
//      - 되면   → SDL 에 창을 맡기고 GL 만 우리가 대는 길이 열린다
//      - 안 되면 → GLFW 때처럼 SDL C API 를 우리 표면 위에 shim 하는 수밖에 없다
//
// ⚠️ dlopen/dlsym 으로 붙는다. 헤더를 앱 타깃에 끌어들이면 빌드 설정이 커지는데,
//    재보는 게 목적이라 그럴 이유가 없다. 실패해도 앱에 아무 영향이 없다.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

// SDL3 의 해당 부분만 옮겨 적는다(ABI 는 SDL3 가 안정성을 약속한다).
#define FLAME_SDL_INIT_VIDEO 0x00000020u

typedef int          (*sdl_init_fn)(unsigned int);
typedef void         (*sdl_setmainready_fn)(void);
typedef void         (*sdl_quit_fn)(void);
typedef const char  *(*sdl_geterror_fn)(void);
typedef int          (*sdl_getversion_fn)(void);
typedef const char  *(*sdl_getcurrentvideodriver_fn)(void);
typedef int          (*sdl_getnumvideodrivers_fn)(void);
typedef const char  *(*sdl_getvideodriver_fn)(int);

/// SDL3 가 이 프로세스에서 초기화되는지 확인하고 결과를 로그로 남긴다.
///
/// 한 번만 돈다. `FLAME_SDL_PROBE` 가 설정돼 있을 때만 — 평소 실행에 SDL 상태를
/// 만들어 둘 이유가 없다(초기화는 UIKit 쪽에 전역 상태를 남긴다).
void flame_probeSDL3(void) {
    if (!getenv("FLAME_SDL_PROBE")) return;
    static BOOL done = NO;
    if (done) return;
    done = YES;

    NSString *path = [NSBundle.mainBundle.bundlePath
                      stringByAppendingPathComponent:@"Frameworks/libSDL3.dylib"];
    void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        printf("[FlameSDL] dlopen 실패: %s\n", dlerror());
        fflush(stdout);
        return;
    }

    sdl_getversion_fn getVersion = (sdl_getversion_fn)dlsym(handle, "SDL_GetVersion");
    sdl_init_fn       init       = (sdl_init_fn)dlsym(handle, "SDL_Init");
    sdl_quit_fn       quit       = (sdl_quit_fn)dlsym(handle, "SDL_Quit");
    sdl_geterror_fn   getError   = (sdl_geterror_fn)dlsym(handle, "SDL_GetError");
    sdl_getcurrentvideodriver_fn current =
        (sdl_getcurrentvideodriver_fn)dlsym(handle, "SDL_GetCurrentVideoDriver");
    sdl_getnumvideodrivers_fn numDrivers =
        (sdl_getnumvideodrivers_fn)dlsym(handle, "SDL_GetNumVideoDrivers");
    sdl_getvideodriver_fn driverName =
        (sdl_getvideodriver_fn)dlsym(handle, "SDL_GetVideoDriver");
    sdl_setmainready_fn setMainReady =
        (sdl_setmainready_fn)dlsym(handle, "SDL_SetMainReady");

    if (!getVersion || !init || !getError) {
        printf("[FlameSDL] 심볼을 찾지 못했습니다 (getVersion=%p init=%p getError=%p)\n",
               (void *)getVersion, (void *)init, (void *)getError);
        fflush(stdout);
        return;
    }

    int v = getVersion();
    printf("[FlameSDL] dlopen 성공 · SDL %d.%d.%d\n",
           v / 1000000, (v / 1000) % 1000, v % 1000);

    if (numDrivers && driverName) {
        int n = numDrivers();
        printf("[FlameSDL] 비디오 드라이버 %d개:", n);
        for (int i = 0; i < n; i++) {
            const char *name = driverName(i);
            printf(" %s", name ? name : "?");
        }
        printf("\n");
    }

    // ⚠️ **이게 없으면 무조건 실패한다.** SDL_InitSubSystem 첫 줄이 이렇다:
    //        if (!SDL_MainIsReady) return SDL_SetError("Application didn't initialize
    //            properly, did you include SDL_main.h ...");
    //    SDL 은 보통 SDL_RunApp 이 진입점을 잡으면서 그 플래그를 세우는데, 우리는
    //    진입점을 내줄 수 없다(FlameAppDelegate + JLI 재진입). SDL_SetMainReady 가
    //    정확히 그런 앱을 위한 탈출구다 — "main 은 내가 이미 처리했다" 는 선언이다.
    if (setMainReady) {
        setMainReady();
        printf("[FlameSDL] SDL_SetMainReady() 호출 — 진입점은 우리가 쥔다\n");
    } else {
        printf("[FlameSDL] ⚠️ SDL_SetMainReady 가 없습니다\n");
    }

    // ⚠️ **메인 스레드에서 불러야 한다.** UIKit_VideoInit 은 UIScreen 열거
    //    (UIKit_InitModes) · GameController · UIPasteboard 를 건드린다. 전부 메인
    //    스레드 전용이다. 지난 시도에서 로그가 SDL_Init 안에서 그냥 끊겼는데
    //    (성공도 실패도 안 찍힘) 그게 이것이다.
    BOOL onMain = NSThread.isMainThread;
    printf("[FlameSDL] SDL_Init 호출 — 현재 스레드: %s\n", onMain ? "메인" : "백그라운드");
    fflush(stdout);

    void (^runInit)(void) = ^{
        int ok = init(FLAME_SDL_INIT_VIDEO);
        if (ok) {
            const char *drv = current ? current() : NULL;
            printf("[FlameSDL] ✅ SDL_Init(VIDEO) 성공 — 드라이버 '%s'\n", drv ? drv : "?");
            printf("[FlameSDL]    → SDL 에 창을 맡기는 길이 열려 있습니다\n");
            if (quit) quit();          // 재보기만 한다. 상태를 남기지 않는다.
        } else {
            printf("[FlameSDL] ❌ SDL_Init(VIDEO) 실패: %s\n", getError());
            printf("[FlameSDL]    → SDL C API 를 우리 표면 위에 shim 해야 합니다\n");
        }
        fflush(stdout);
    };

    if (onMain) {
        runInit();
    } else {
        // ⚠️ dispatch_sync 로 메인을 기다리지 않는다. 부팅 경로가 메인 스레드의 작업을
        //    기다리고 있으면 서로 물려 멈춘다. 결과는 로그로만 받으면 된다.
        dispatch_async(dispatch_get_main_queue(), runInit);
    }
}
