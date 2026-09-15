//
//  FlameNative.h — Swift ↔ 네이티브 경계.
//
//  PojavLauncher iOS 의 네이티브 계층(JavaLauncher / input_bridge_v3 / egl_bridge /
//  ctxbridges)을 이 앱에 맞게 옮긴 것이다. Swift 쪽 `FlameNativeRuntime` 이 여기 선언된
//  함수만 호출하고, 그 아래 JNI·GLFW·GL 사정은 전부 감춘다.
//
//  ⚠️ 별도 dylib 이 아니라 **앱 바이너리에 함께 컴파일**된다. 마인크래프트가 쓰는 패치된
//     LWJGL(lwjgl-glfw.jar)이 `Java_org_lwjgl_glfw_*` 심볼을 JNI 로 찾는데, JVM 은 프로세스
//     전역 심볼 테이블(메인 실행 파일 포함)에서 찾으므로 이렇게 하면 그대로 연결된다.
//     (안드로이드판이 libflamejvm.so 를 따로 만든 것과 다른 점 — iOS 는 앱이 곧 그 라이브러리다.)
//
#pragma once

#import <UIKit/UIKit.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

/// 게임이 그려질 레이어. JVM 부팅 **전에** 반드시 설정해야 한다.
/// GL4ES/ANGLE 경로는 CAMetalLayer 를, OSMesa(Zink) 경로는 일반 CALayer 를 기대한다.
void FlameNativeSetSurfaceLayer(CALayer *_Nullable layer);

/// LWJGL 할당자로 넘길 함수 포인터 여섯 개(malloc, calloc, realloc, free,
/// aligned_alloc, aligned_free). 큰 할당을 파일 기반 매핑으로 돌려 jetsam 장부에서
/// 빼기 위한 것이다 — 자세한 사정은 `flame_alloc.c` 주석.
void flame_alloc_pointers(uint64_t out[6]);

/// 지금 파일 기반으로 들고 있는 바이트 / 매핑에 실패해 malloc 으로 떨어진 횟수.
uint64_t flame_alloc_mapped_bytes(void);
uint64_t flame_alloc_map_failures(void);

/// 프레임버퍼 크기(픽셀). 해상도 배율이 적용된 값을 넘긴다.
void FlameNativeSetScreenSize(int width, int height);

/// 파일시스템을 건드리지 않고 경로를 정규화한다(`.` 제거, `..` 되감기).
/// `out` 은 PATH_MAX 이상이어야 한다.
void FlameNativeLexicalRealpath(const char *path, char *out);

/// 환경변수 설정. JVM 부팅 전에 호출할 것.
void FlameNativeSetEnv(const char *key, const char *value);

/// `FlameNativeLaunchJVM` 의 실패 코드. 0 이상이면 JVM 이 그 코드로 종료했다는 뜻.
enum {
    FLAME_LAUNCH_ERR_SIMULATOR = -1,   ///< 시뮬레이터 — 기기용 바이너리라 열 수 없다
    FLAME_LAUNCH_ERR_NO_JLI    = -2,   ///< JRE 에 libjli.dylib 이 없다
    FLAME_LAUNCH_ERR_DLOPEN    = -3,   ///< libjli dlopen 실패
    FLAME_LAUNCH_ERR_NO_SYMBOL = -4,   ///< JLI_Launch 심볼 없음
    FLAME_LAUNCH_ERR_NO_DEBUGGER = -5, ///< iOS 26+TXM 인데 디버거가 붙어 있지 않다
    FLAME_LAUNCH_ERR_JIT_SCRIPT = -6,  ///< StikDebug 에 JIT 스크립트가 지정되지 않았다
};

/// JVM 을 띄우고 mainClass 를 실행한다. **돌아오지 않는 블로킹 호출**이므로
/// 전용 스레드에서 부를 것. 실패 시 음수 반환.
/// @param javaHome  JRE 루트(그 아래 bin/, lib/ 가 있어야 한다)
/// @param argv      java 실행 파일에 넘기듯 구성한 전체 인자 (argv[0] 은 java 경로)
int FlameNativeLaunchJVM(const char *javaHome, const char *_Nonnull *_Nonnull argv, int argc);

/// JLI 가 `apple_main` 에서 앱 진입점을 다시 호출한 경우, 이 스레드에서 JVM 을 이어 실행한다.
///
/// Darwin OpenJDK 런처의 정상 동작이다 — JVM 은 JLI 가 만든 그 스레드에서 돌아야 한다.
/// 재진입 때 SwiftUI 를 다시 띄우면 "AppGraph.shared may only be set once" 로 죽는다.
///
/// - Returns: 재진입이 아니면 false(호출자는 평소대로 앱을 띄우면 된다). true 면 돌아오지 않는다.
bool FlameNativeContinueJVM(void);

/// 게임이 마우스를 잡고 있는지(=인게임). false 면 메뉴/인벤토리.
bool FlameNativeIsGrabbing(void);

/// 마지막 1초간 실제로 스왑된 프레임 수. 아직 한 프레임도 안 나왔으면 -1.
int FlameNativeCurrentFPS(void);

/// jetsam 까지 남은 여유(MB). 알 수 없으면 -1.
int FlameNativeAvailableMemoryMB(void);
/// 현재 물리 메모리 사용량(MB). 알 수 없으면 -1.
int FlameNativeMemoryFootprintMB(void);

/// 자바 스레드 덤프를 로그(latestlog.txt)에 남긴다.
void FlameNativeDumpThreads(void);

/// 첫 프레임이 그려졌는지 — 부팅 오버레이를 내릴 시점 판단에 쓴다.
bool FlameNativeHasRendered(void);

// ── 입력 중계 (GLFW 콜백으로 들어간다) ──
void FlameNativeSendKey(int key, int scancode, int action, int mods);
void FlameNativeSendChar(unsigned int codepoint);
void FlameNativeSendMouseButton(int button, int action, int mods);
/// @param mode 0=절대좌표(메뉴) 1=상대델타(인게임)
void FlameNativeSendCursorPos(int mode, double x, double y);
void FlameNativeSendScroll(double dx, double dy);

/// 게임에 ESC 를 보내 일시정지시킨다(앱이 백그라운드로 갈 때).
void FlameNativePauseGame(void);

// ── JIT ──
//
// 서명된 iOS 앱은 W^X 때문에 실행 가능한 메모리에 코드를 쓸 수 없고, HotSpot 은 인터프리터
// 템플릿부터 런타임에 생성하므로 JIT 없이는 사실상 못 돈다. 커널은 CS_DEBUGGED 가 선
// 프로세스에만 예외를 준다. 자세한 배경은 flame_jit.m 머리말 참고.

/// `csops` 의 CS_DEBUGGED 플래그가 서 있는지. **이것만으로는 부족하다** —
/// 플래그가 켜져 있어도 커널이 실행 권한을 안 주는 경우가 있다(iOS 26 에서 실측).
bool FlameNativeIsJITEnabled(void);

/// JIT 전용 메모리(MAP_JIT)를 확보할 수 있는지. **실행은 시도하지 않는다.**
///
/// ⚠️ 실행해 보는 방식으로 확인하면 안 된다 — 막힌 페이지로 점프하면 iOS 26 은
///    잡을 수 없는 SIGKILL 로 프로세스를 죽인다(sigsetjmp 로도 못 막는다).
bool FlameNativeCanAllocateJITMemory(void);

/// 커널이 실제로 내준 메모리 권한까지 확인하는 진단 문자열.
/// 실행은 하지 않는다 — 막힌 페이지를 실행하면 잡을 수 없는 SIGKILL 이 난다.
NSString *FlameNativeJITProbe(void);

/// 게임이 `exit()` 를 불렀을 때 오는 알림. object 는 종료 코드(NSNumber).
/// 프로세스는 끝나지 않는다 — 런처 화면으로 돌아가는 신호로 쓴다.
extern NSString *const FlameGameDidExitNotification;

// MARK: - JIT26 (iOS 26 디버거 보조 JIT)
//
// 번들 JRE 의 libjvm.dylib 이 이 규약으로 패치돼 있다. 자세한 배경은 flame_jit26.m 참고.

typedef NS_OPTIONS(NSUInteger, FlameJITFlags) {
    FlameJITFlagIsIOS26      = 1 << 0,
    FlameJITFlagForceMirrored = 1 << 1,
    FlameJITFlagHasTXM       = 1 << 2,
};

FlameJITFlags FlameNativeGetJITFlags(BOOL refresh);
BOOL FlameNativeHasJITFlags(FlameJITFlags flags);

/// 디버거에게 RX 영역을 요청한다(레거시 brk #0x69). JVM 이 쓰는 것과 같은 경로라,
/// 스크립트가 제대로 붙었는지 확인하는 용도로도 쓴다.
void *JIT26CreateRegionLegacy(size_t len);
void *JIT26PrepareRegion(void *addr, size_t len);
void JIT26PrepareRegionForPatching(void *addr, size_t size);
void JIT26SetDetachAfterFirstBr(BOOL value);
/// 디버거에 추가 JS 를 보내 핸들러를 심는다. JVM 의 brk #0x69 를 받으려면 필수.
void JIT26SendJITScript(NSString *script);
/// 디버거가 지금도 붙어 있는지(CS_DEBUGGED 는 한 번 서면 남으므로 그것만으론 부족).
BOOL JIT26IsLikelyDebuggerKeepAttached(void);
BOOL DeviceCanCreateRXMap(void);
/// libjvm 이 dlsym 으로 찾는 심볼. 이름 고정.
BOOL DeviceHasTXM(void);

/// 커널이 실제로 실행 권한을 주는지. CS_DEBUGGED 가 서 있어도 false 일 수 있다.
bool FlameNativeHasExecutableMemory(void);

/// 디버거가 붙을 수 있는 서명인지(get-task-allow). 없으면 어떤 방법으로도 JIT 를 못 켠다.
bool FlameNativeIsDebuggable(void);

/// "TrollStore" / "Jailbroken" / "Simulator" / "Unjailbroken"
NSString *FlameNativeInstallType(void);

bool FlameNativeIsJailbroken(void);
BOOL FlameNativeHasEntitlement(NSString *key);

/// TrollStore 가 JIT 를 켜줄 수 있는 상태인지 (com.apple.private.local.sandboxed-jit).
bool FlameNativeHasTrollStoreJIT(void);

/// TrollStore 에 JIT 활성화를 요청한다(URL 스킴). 앱이 잠깐 전환됐다 돌아온다.
/// @return 요청을 보냈으면 true. false 면 이 경로를 쓸 수 없다는 뜻.
bool FlameNativeRequestTrollStoreJIT(void);

/// StikDebug(17.4+) / SideStore 에게 JIT 활성화를 요청한다.
/// JIT 스크립트를 URL 에 실어 보내므로 도구 쪽에서 따로 지정할 필요가 없다.
bool FlameNativeRequestDebuggerJIT(void);

/// AltKit 이 번들에 들어 있는지 — 없으면 AltServer 경로는 쓸 수 없다.
bool FlameNativeAltServerAvailable(void);

/// 같은 Wi-Fi 의 AltServer(AltStore/SideStore)를 찾아 JIT 활성화를 요청한다.
/// 완료 핸들러는 아무 스레드에서나 불릴 수 있다.
void FlameNativeRequestAltServerJIT(void (^completion)(bool success, NSString *_Nullable message));

void FlameNativeStopAltServerDiscovery(void);

/// 진단 문자열 — 왜 못 도는지 사용자에게 그대로 보여준다.
NSString *FlameNativeDiagnostics(void);

/// 버전 전환용 JIT 요청. pid 대신 bundle-id 만 넘겨 **새 프로세스**를 대상으로 한다.
/// 부른 쪽은 곧바로 스스로 종료해야 한다 — 자세한 사정은 구현부 주석 참고.
bool FlameNativeRequestDebuggerJITForRelaunch(void);

#pragma mark - 테라코타(온라인 LAN)

/// 테라코타의 로컬 제어 서버를 띄우고 **실제로 열린 포트**를 돌려준다. 실패하면 0.
///
/// 테라코타의 제어 표면은 전부 HTTP 다(데스크톱 UI 가 그걸 쓴다). 그래서 네이티브
/// 진입점은 이 하나뿐이고, 나머지(상태 조회·방 열기·참가)는 스위프트가
/// http://127.0.0.1:<포트>/state/… 로 부른다.
///
/// 포트는 OS 가 고른다 — 고정 포트는 다른 앱과 부딪힌다.
/// 한 프로세스에서 한 번만 뜬다. 두 번째 호출부터는 0 을 돌려준다.
uint16_t terracotta_ios_start(const char *dataDir);

NS_ASSUME_NONNULL_END
