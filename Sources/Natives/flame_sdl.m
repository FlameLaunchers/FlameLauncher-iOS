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

#import <UIKit/UIKit.h>   // flame_environ.h 가 CALayer 를 쓴다
#include <dlfcn.h>
#import <objc/runtime.h>
#include <stdio.h>

#include "flame_environ.h"

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
/// 잡히지 않은 Objective-C 예외의 **심볼 있는 스택**을 남긴다.
///
/// ⚠️ SDL 의 uikit 백엔드는 "SDL 이 앱을 소유한다"는 전제로 쓰여 있어서, 어느 함수가
///    UIKit 을 타는지 목록이 따로 없다. 공개 진입점을 37개까지 메인 스레드로 감쌌는데도
///    같은 자리에서 같은 예외가 났다:
///      'These UI changes are not supported off the main thread.'
///    주소만 나오는 기본 스택으로는 어느 함수인지 알 수 없어서 계속 찍어 맞혀야 했다.
///    여기서 이름을 찍으면 한 번에 끝난다.
static void flame_exceptionHandler(NSException *e) {
    printf("\n[FlameExc] %s: %s\n", e.name.UTF8String, e.reason.UTF8String);
    for (NSString *frame in e.callStackSymbols) {
        printf("[FlameExc]   %s\n", frame.UTF8String);
    }
    fflush(stdout);
}

/// SDL 의 숨은 입력칸이 소프트 키보드를 스스로 띄우지 못하게 한다.
///
/// 26.3 은 화면이 열리면서 입력칸에 스스로 포커스를 준다(싱글플레이의 월드 검색칸 등).
/// 그러면 SDL 이 -[SDL_uikitviewcontroller startTextInput] 에서 숨겨 둔 UITextField 를
/// 첫 응답자로 세우고, iOS 는 그 순간 키보드를 띄운다 — 들어가자마자 키보드가 화면을 가렸다.
/// ⚠️ SDL_ENABLE_SCREEN_KEYBOARD=0 으로는 안 막힌다(실측). uikit 백엔드는 StartTextInput
///    자체가 becomeFirstResponder 라서, 힌트가 막는 ShowScreenKeyboard 를 거치지 않는다.
/// 빈 inputView 를 달면 첫 응답자는 되되(하드웨어 키보드 입력은 그대로) 소프트 키보드는 안 뜬다.
/// 소프트 키보드는 화면의 키보드 버튼(GameKeyInputView)으로 연다 — 다른 버전과 같다.
static void flame_suppressSDLAutoKeyboard(void) {
    Class vc = NSClassFromString(@"SDL_uikitviewcontroller");
    SEL sel = NSSelectorFromString(@"startTextInput");
    Method method = vc ? class_getInstanceMethod(vc, sel) : NULL;
    Ivar ivar = vc ? class_getInstanceVariable(vc, "textField") : NULL;
    if (!method || !ivar) {
        printf("[FlameSDL] 키보드 자동 표시를 못 막았습니다 (method=%p ivar=%p)\n",
               (void *)method, (void *)ivar);
        return;
    }
    bool (*original)(id, SEL) = (bool (*)(id, SEL))method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^bool(id self) {
        UITextField *field = object_getIvar(self, ivar);
        if (field && !field.inputView) field.inputView = [[UIView alloc] initWithFrame:CGRectZero];
        return original(self, sel);
    }));
    printf("[FlameSDL] 입력칸 포커스 때 키보드 자동 표시를 끕니다\n");
}

void flame_probeSDL3(void) {
    if (!getenv("FLAME_SDL_PROBE")) return;
    static BOOL done = NO;
    if (done) return;
    done = YES;

    NSSetUncaughtExceptionHandler(flame_exceptionHandler);

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
    flame_suppressSDLAutoKeyboard();

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

// MARK: - 26.3+ 입력: 화면 버튼·터치를 SDL 이벤트로
//
// ⚠️ 26.3 은 입력을 **SDL_PollEvent 로만** 읽는다(com.mojang.blaze3d.platform.SDLEventHandler).
//    우리 입력은 전부 GLFW 콜백으로 가는데 그 버전에는 GLFW 가 없어서, 화면 버튼을 눌러도
//    아무 데도 닿지 않는다. 같은 입력을 SDL 이벤트로 넣는다.
//
//    26.3 이 실제로 읽는 값 (클라이언트 jar 을 javap 로 확인):
//      키     scancode = SDL 스캔코드(= HID usage, InputConstants.KEY_W = 26), mod = SDL_Keymod
//      버튼   1 좌 · 2 가운데 · 3 우 (InputConstants.MOUSE_BUTTON_*)
//      이동   x/y 는 창 좌표(pt). grab 중에는 xrel/yrel 만 누적한다(MouseHandler.onMove)
//      공통   windowID 가 게임 창이 아니면 버린다(onMove 첫 줄이 창 핸들 비교)
//
// ⚠️ SDL_PushEvent 는 SDL 의 **내부 상태를 안 바꾼다**(SDL_events.h). 게임이 상태를 직접
//    읽는 두 곳은 공개 API 로 맞춘다:
//      SDL_GetModState    클릭의 Shift(MouseButtonInfo) — 수식키를 누적해 SDL_SetModState
//      SDL_GetMouseState  화면이 열릴 때 커서 재동기화 — 절대 이동은 SDL_WarpMouseInWindow 로
//                         (uikit 에는 WarpMouse 구현이 없어 SDL 이 진짜 이동 이벤트를 낸다)

// SDL_events.h 에서 필요한 것만 옮긴다(ABI 는 SDL3 가 고정을 약속한다). 크기는 128바이트.
typedef union {
    uint32_t type;
    struct { uint32_t type, reserved; uint64_t timestamp; uint32_t windowID, which;
             int32_t scancode; uint32_t key; uint16_t mod, raw; bool down, repeat; } key;
    struct { uint32_t type, reserved; uint64_t timestamp; uint32_t windowID;
             const char *text; } text;
    struct { uint32_t type, reserved; uint64_t timestamp; uint32_t windowID, which, state;
             float x, y, xrel, yrel; } motion;
    struct { uint32_t type, reserved; uint64_t timestamp; uint32_t windowID, which;
             uint8_t button; bool down; uint8_t clicks, padding; float x, y; } button;
    struct { uint32_t type, reserved; uint64_t timestamp; uint32_t windowID, which;
             float x, y; int32_t direction; float mouse_x, mouse_y; int32_t integer_x, integer_y; } wheel;
    uint8_t padding[128];
} FlameSDLEvent;

enum {
    FLAME_SDL_KEY_DOWN = 0x300, FLAME_SDL_KEY_UP = 0x301, FLAME_SDL_TEXT_INPUT = 0x303,
    FLAME_SDL_MOUSE_MOTION = 0x400, FLAME_SDL_BUTTON_DOWN = 0x401, FLAME_SDL_BUTTON_UP = 0x402,
    FLAME_SDL_MOUSE_WHEEL = 0x403,
};

static struct {
    bool     (*PushEvent)(FlameSDLEvent *);
    void    *(*GetKeyboardFocus)(void);
    uint32_t (*GetWindowID)(void *);
    bool     (*GetWindowSize)(void *, int *, int *);
    bool     (*GetWindowRelativeMouseMode)(void *);
    void     (*WarpMouseInWindow)(void *, float, float);
    uint32_t (*GetKeyFromScancode)(int32_t, uint16_t, bool);
    void     (*SetModState)(uint16_t);
} sdl;

/// 게임의 SDL 창. 없으면 NULL — 호출자는 GLFW 경로로 간다(26.2 이하 · 아직 부팅 중).
///
/// ⚠️ "libSDL3 이 열려 있다" 로는 못 가린다. 프로브가 모든 버전에서 연다(flame_probeSDL3).
///    **창이 있어야** 26.3 이다. 전부 메인 스레드(Swift 입력)에서만 불린다.
static void *flame_sdlWindow(void) {
    static void *window;
    if (!sdl.PushEvent) {
        NSString *path = [NSBundle.mainBundle.bundlePath
                          stringByAppendingPathComponent:@"Frameworks/libSDL3.dylib"];
        void *h = dlopen(path.UTF8String, RTLD_NOLOAD | RTLD_LAZY);   // 이미 열려 있을 때만
        if (!h) return NULL;
#define FLAME_SDL_LOAD(name) sdl.name = (__typeof__(sdl.name))dlsym(h, "SDL_" #name)
        FLAME_SDL_LOAD(GetKeyboardFocus);
        FLAME_SDL_LOAD(GetWindowID);
        FLAME_SDL_LOAD(GetWindowSize);
        FLAME_SDL_LOAD(GetWindowRelativeMouseMode);
        FLAME_SDL_LOAD(WarpMouseInWindow);
        FLAME_SDL_LOAD(GetKeyFromScancode);
        FLAME_SDL_LOAD(SetModState);
        FLAME_SDL_LOAD(PushEvent);   // 마지막 — 이게 서 있으면 나머지도 채워진 것이다
#undef FLAME_SDL_LOAD
    }
    void *focus = sdl.GetKeyboardFocus();
    if (focus) window = focus;
    // 창이 없어졌으면 0 이 나온다 — SDL3 는 객체 포인터를 검증하므로 묵은 포인터도 안전하다.
    return window && sdl.GetWindowID(window) ? window : NULL;
}

/// SDL_PushEvent 는 수식키 상태를 안 바꾸므로 여기서 누적한다.
static uint16_t flame_sdlMods;

bool flame_sdl_sendKey(int scancode, int action) {
    void *w = flame_sdlWindow();
    if (!w) return false;
    if (scancode <= 0) return true;   // 26.3 에 대응하는 키가 없다

    bool down = action != 0;
    // LCtrl LShift LAlt LGui RCtrl RShift RAlt RGui (스캔코드 224~231) → SDL_KMOD_* 비트
    static const uint16_t modBits[8] = { 0x0040, 0x0001, 0x0100, 0x0400, 0x0080, 0x0002, 0x0200, 0x0800 };
    if (scancode >= 224 && scancode <= 231) {
        uint16_t bit = modBits[scancode - 224];
        flame_sdlMods = down ? (flame_sdlMods | bit) : (flame_sdlMods & ~bit);
        sdl.SetModState(flame_sdlMods);
    }

    FlameSDLEvent e = {0};
    e.key.type = down ? FLAME_SDL_KEY_DOWN : FLAME_SDL_KEY_UP;
    e.key.windowID = sdl.GetWindowID(w);
    e.key.scancode = scancode;
    e.key.key = sdl.GetKeyFromScancode(scancode, flame_sdlMods, true);
    e.key.mod = flame_sdlMods;
    e.key.down = down;
    e.key.repeat = action == 2;
    sdl.PushEvent(&e);
    return true;
}

bool flame_sdl_sendChar(unsigned int codepoint) {
    void *w = flame_sdlWindow();
    if (!w) return false;

    // ⚠️ text 는 포인터다. 렌더 스레드가 이 이벤트를 꺼내 읽을 때까지 살아 있어야 한다.
    // ponytail: 256칸 링 — 게임이 한 번에 256글자 넘게 밀리면 앞 글자가 덮인다. 그땐 이벤트마다 할당으로.
    static char ring[256][5];
    static unsigned slot;
    char *text = ring[slot++ % 256];
    NSString *s = [[NSString alloc] initWithBytes:&codepoint length:sizeof codepoint
                                         encoding:NSUTF32LittleEndianStringEncoding];
    strlcpy(text, s.UTF8String ?: "", sizeof ring[0]);

    FlameSDLEvent e = {0};
    e.text.type = FLAME_SDL_TEXT_INPUT;
    e.text.windowID = sdl.GetWindowID(w);
    e.text.text = text;
    sdl.PushEvent(&e);
    return true;
}

bool flame_sdl_sendMouseButton(int glfwButton, int action) {
    void *w = flame_sdlWindow();
    if (!w) return false;
    if (glfwButton < 0 || glfwButton > 2) return true;

    static const uint8_t sdlButton[3] = { 1, 3, 2 };   // GLFW 좌·우·가운데 → SDL 1·3·2
    FlameSDLEvent e = {0};
    e.button.type = action ? FLAME_SDL_BUTTON_DOWN : FLAME_SDL_BUTTON_UP;
    e.button.windowID = sdl.GetWindowID(w);
    e.button.button = sdlButton[glfwButton];
    e.button.down = action != 0;
    e.button.clicks = 1;
    sdl.PushEvent(&e);
    return true;
}

/// @param mode 0 = 절대좌표(우리 프레임버퍼 px), 1 = 상대델타(인게임 시점 회전)
bool flame_sdl_sendCursorPos(int mode, double x, double y) {
    void *w = flame_sdlWindow();
    if (!w) return false;

    if (mode == 1) {
        FlameSDLEvent e = {0};
        e.motion.type = FLAME_SDL_MOUSE_MOTION;
        e.motion.windowID = sdl.GetWindowID(w);
        e.motion.xrel = (float)x;
        e.motion.yrel = (float)y;
        sdl.PushEvent(&e);
        return true;
    }

    // Swift 는 해상도 배율이 적용된 **우리 프레임버퍼 px** 로 준다(GLFW 경로 규칙).
    // SDL 창 좌표는 pt 라 비율로 되돌린다.
    int ww = 0, wh = 0;
    if (windowWidth > 0 && windowHeight > 0 && sdl.GetWindowSize(w, &ww, &wh)) {
        sdl.WarpMouseInWindow(w, (float)(x * ww / windowWidth), (float)(y * wh / windowHeight));
    }
    return true;
}

bool flame_sdl_sendScroll(double dx, double dy) {
    void *w = flame_sdlWindow();
    if (!w) return false;

    FlameSDLEvent e = {0};
    e.wheel.type = FLAME_SDL_MOUSE_WHEEL;
    e.wheel.windowID = sdl.GetWindowID(w);
    e.wheel.x = (float)dx;
    e.wheel.y = (float)dy;
    e.wheel.integer_x = (int32_t)dx;
    e.wheel.integer_y = (int32_t)dy;
    sdl.PushEvent(&e);
    return true;
}

/// 게임이 마우스를 잡고 있으면 1, 아니면 0. SDL 창이 없으면 -1(GLFW 쪽 상태를 볼 것).
/// 26.3 은 grab 을 SDL_SetWindowRelativeMouseMode 로 건다(InputConstants.grabMouse).
int flame_sdl_isGrabbing(void) {
    void *w = flame_sdlWindow();
    return w ? sdl.GetWindowRelativeMouseMode(w) : -1;
}
