//
//  flame_launcher.m — JVM 부팅 + Swift 로 노출하는 C API.
//  PojavLauncher iOS 의 JavaLauncher.m / utils.m 을 옮긴 것.
//
//  ⚠️ JNI_CreateJavaVM 이 아니라 **JLI_Launch** 를 쓴다. JLI 는 `java` 실행 파일이 하는 일
//     (인자 파싱, -cp 처리, main 클래스 리플렉션 호출, 예외 출력)을 전부 대신해 준다.
//     JNI_CreateJavaVM 으로 직접 하면 그걸 다 재구현해야 하고, --add-opens 같은 인자도
//     JLI 만 제대로 해석한다.
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>

#include <mach/mach.h>
#include <dlfcn.h>
#include <setjmp.h>
#include <signal.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <stdarg.h>
#include <limits.h>
#include <sys/stat.h>
#include <os/proc.h>

#include "FlameNative.h"
#include "fishhook/fishhook.h"
#include "flame_environ.h"
#include "include/glfw_keycodes.h"

// utils.h 의 것들 (dyld_bypass_validation.m 이 참조한다)
BOOL debugLogEnabled = NO;
BOOL isJailbroken = NO;

void init_bypassDyldLibValidation(void);
BOOL PLPatchMachOPlatformForFile(const char *path);
void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods);
bool CallbackBridge_nativeSendChar(jchar codepoint);
void CallbackBridge_nativeSendMouseButton(int button, int action, int mods);
void CallbackBridge_nativeSendCursorPos(char event, CGFloat x, CGFloat y);
void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset);
void CallbackBridge_pauseGameIfNeed(void);

/// 첫 호출에서 저장해 둔 JLI 진입점과 인자.
///
/// ⚠️ Darwin JLI 는 `apple_main` 이라는 새 pthread 를 만들어 **호스트 실행 파일의 `main`**
///    을 다시 호출한다(`dlsym(RTLD_DEFAULT, "main")`). 그게 정상 설계다 — JVM 은 그
///    스레드에서 돌아야 한다. 그래서 재진입 때는 SwiftUI 를 다시 띄우는 대신
///    여기 저장해 둔 것으로 JLI_Launch 를 다시 부른다.
///    (PojavLauncher / Amethyst 의 main.m 도 `if (pJLI_Launch) return pJLI_Launch(...)` 로 같은 일을 한다)
static void *flameSavedJLILaunch;
static int flameSavedArgc;
static char **flameSavedArgv;

typedef int JLI_Launch_func(int argc, char **argv,
                            int jargc, const char **jargv,
                            int appclassc, const char **appclassv,
                            const char *fullversion, const char *dotversion,
                            const char *pname, const char *lname,
                            jboolean javaargs, jboolean cpwildcard,
                            jboolean javaw, jint ergo);

// MARK: - 표면 / 화면

void FlameNativeSetSurfaceLayer(CALayer *layer) {
    flameSurfaceLayer = layer;
}

void FlameNativeSetScreenSize(int width, int height) {
    CallbackBridge_nativeSendScreenSize(width, height);
}

void FlameNativeSetEnv(const char *key, const char *value) {
    setenv(key, value, 1);
}

// MARK: - 메모리

/// jetsam 으로 죽기까지 **이 앱에 남은 여유**(MB).
///
/// ⚠️ iOS 에는 앱용 swap 이 없다. 물리 메모리를 한도 이상 쓰면 경고도 로그도 없이
///    SIGKILL 로 사라진다 — 자바의 OutOfMemoryError 와는 전혀 다른 죽음이라
///    로그가 문장 중간에서 끊기고 크래시 리포트도 안 남는다.
///    `os_proc_available_memory()` 가 그 한도까지 남은 바이트를 알려준다.
int FlameNativeAvailableMemoryMB(void) {
    size_t available = os_proc_available_memory();
    return available == 0 ? -1 : (int)(available / (1024 * 1024));
}

/// 지금 이 프로세스가 쓰고 있는 물리 메모리(MB). jetsam 이 보는 값이다.
int FlameNativeMemoryFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
    return (int)(info.phys_footprint / (1024 * 1024));
}

static void flame_dumpJavaStacks(void);

/// 모든 **네이티브** 스레드의 스택을 찍는다.
///
/// ⚠️ 자바 쪽 덤프(JVM_DumpAllStacks)는 VM 이 세이프포인트에 도달해야 한다. 그런데 우리가
///    알고 싶은 상황은 대개 **스레드가 네이티브에 처박혀 세이프포인트에 못 가는** 경우다
///    — 그럴 때 자바 덤프는 영영 돌아오지 않는다. 실제로 그것 때문에 메인 스레드가 막혀
///    iOS 워치독이 앱을 죽였다. 이쪽은 JVM 협조가 필요 없으니 언제나 답을 준다.
///
/// ⚠️ 스레드를 멈춘 채로는 **아무것도 할당하면 안 된다.** dladdr 도 malloc 을 쓸 수 있어서,
///    멈춘 스레드가 malloc 락을 쥐고 있으면 그대로 데드락이다.
///    그래서 멈춘 동안에는 PC 만 고정 버퍼에 담고, 심볼 변환은 재개한 뒤에 한다.
static void flame_dumpNativeStacks(void) {
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        printf("[FlameDump] 스레드 목록을 못 얻었습니다\n");
        return;
    }

    thread_t self = mach_thread_self();
    printf("\n===== [FlameDump] 네이티브 스택 (%u 스레드) =====\n", count);

    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (threads[i] == self) continue;

        // 최대 32 프레임. 멈춘 동안에는 이 배열에만 쓴다.
        uintptr_t frames[32];
        int depth = 0;

        {
            // ⚠️ 스레드를 **멈추지 않는다.** 멈춘 채로 dladdr(dyld 락)이나 printf(stdio 락)를
            //    부르면, 하필 그 락을 쥔 스레드를 우리가 멈춰 놨을 때 그대로 데드락이다.
            //    실제로 그렇게 프로세스 전체가 굳었다 — 자바 메인 스레드가 park 에 멈춘
            //    것처럼 보였는데, 사실은 이 함수가 붙잡고 있었던 것이다.
            //    안 멈추면 스택이 살짝 어긋날 수 있지만, 정작 우리가 보고 싶은 "멈춘 스레드"는
            //    어차피 움직이지 않으므로 실용적으로 문제가 없다.
            arm_thread_state64_t state;
            mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(threads[i], ARM_THREAD_STATE64,
                                 (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
                frames[depth++] = (uintptr_t)arm_thread_state64_get_pc(state);
                uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
                // 프레임 포인터 체인: fp[0] = 이전 fp, fp[1] = 복귀 주소.
                //
                // ⚠️ 그냥 역참조하면 안 된다. 스레드가 프레임을 세우는 중이거나 JIT 코드가
                //    프레임 포인터를 다르게 쓰면 fp 가 매핑되지 않은 주소를 가리키고,
                //    그 순간 SIGSEGV 로 **프로세스가 죽는다**. 실제로 그렇게 죽였다:
                //      # Problematic frame: C [FlameLauncher] flame_dumpNativeStacks+0x174
                //    vm_read_overwrite 는 못 읽으면 오류를 돌려줄 뿐 죽지 않는다.
                while (depth < 32 && fp > 0x1000 && (fp & 0xF) == 0) {
                    uintptr_t pair[2];
                    vm_size_t read = 0;
                    if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
                                          sizeof(pair), (vm_address_t)pair, &read) != KERN_SUCCESS
                        || read != sizeof(pair)) break;
                    uintptr_t next = pair[0], lr = pair[1];
                    if (lr < 0x1000 || next <= fp) break;
                    frames[depth++] = lr;
                    fp = next;
                }
            }
        }

        if (depth == 0) continue;
        printf("--- thread %u ---\n", threads[i]);
        for (int f = 0; f < depth; f++) {
            Dl_info info;
            if (dladdr((void *)frames[f], &info) && info.dli_sname) {
                const char *image = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
                printf("  %2d  %-28s %s + %lu\n", f,
                       image ? image + 1 : "?", info.dli_sname,
                       (unsigned long)(frames[f] - (uintptr_t)info.dli_saddr));
            } else {
                printf("  %2d  0x%lx\n", f, (unsigned long)frames[f]);
            }
        }
    }
    printf("===== [FlameDump] 네이티브 끝 =====\n");
    fflush(stdout);
    mach_port_deallocate(mach_task_self(), self);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
}

/// 스레드 덤프를 로그에 남긴다. 네이티브 스택은 항상, 자바 스택은 붙을 수 있을 때만.
///
/// ⚠️ **메인 스레드에서 부르면 안 된다.** 자바 덤프는 VM 이 멈춰 있으면 돌아오지 않고,
///    메인 스레드가 몇 초 막히면 iOS 워치독이 앱을 죽인다(실제로 그렇게 죽였다).
///    호출부가 실수해도 안전하도록 여기서 백그라운드로 넘긴다.
void FlameNativeDumpThreads(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        flame_dumpNativeStacks();
        flame_dumpJavaStacks();
    });
}

/// 자바 스택. VM 이 건강할 때만 쓸모가 있다 — 못 붙으면 그냥 넘어간다.
static void flame_dumpJavaStacks(void) {
    if (!runtimeJavaVMPtr) {
        printf("[FlameDump] JVM 이 아직 없습니다\n");
        fflush(stdout);
        return;
    }

    void (*dumpAllStacks)(void *, void *) = dlsym(RTLD_DEFAULT, "JVM_DumpAllStacks");
    if (!dumpAllStacks) {
        printf("[FlameDump] JVM_DumpAllStacks 를 찾지 못했습니다\n");
        fflush(stdout);
        return;
    }

    // 이 스레드는 JVM 이 모르는 네이티브 스레드다 — 붙였다 떼야 JNIEnv 를 쓸 수 있다.
    JNIEnv *env = NULL;
    if ((*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, (void **)&env, NULL) != JNI_OK) {
        printf("[FlameDump] JVM 에 붙지 못했습니다\n");
        fflush(stdout);
        return;
    }

    printf("\n===== [FlameDump] 자바 스레드 덤프 =====\n");
    fflush(stdout);
    dumpAllStacks(env, NULL);
    fflush(stdout);
    printf("===== [FlameDump] 끝 =====\n");
    fflush(stdout);

    (*runtimeJavaVMPtr)->DetachCurrentThread(runtimeJavaVMPtr);
}

/// 2초마다 여유를 로그에 남긴다.
///
/// 이게 없으면 jetsam 으로 죽었을 때 "로그가 그냥 끊겼다" 외에 아무 단서가 없다.
/// 마지막 줄의 여유를 보면 한도에 부딪힌 것인지, 아니면 다른 이유인지 바로 갈린다.
/// 힙 밖 메모리가 **어디에** 있는지 태그별로 모아 찍는다.
///
/// ⚠️ `[FlameMem]` 의 총량만으로는 아무것도 못 고친다. 실측(바닐라 1.21.4 + 서버
///    리소스팩)에서 죽는 순간이 전체 3069 MB = 자바 힙 커밋 928 MB + **힙 밖 2141 MB**
///    였는데, 8192² 아틀라스는 그중 256 MB(12%)에 불과했다. 아틀라스를 줄여 화질만
///    잃고 메모리는 그대로였다. 나머지 1.9 GB 가 무엇인지 모르면 계속 헛짚는다.
///
///    jetsam 이 보는 건 phys_footprint 이고, 그건 결국 각 VM 영역의 **더티 페이지**
///    합이다. 그래서 주소 공간을 훑어 user_tag 별로 더해 본다. malloc 이 크면 JVM/
///    NativeImage 쪽, IOKit·IOAccelerator 가 크면 GPU 쪽이다.
static void flame_dumpMemoryRegions(void) {
    static const struct { unsigned tag; const char *name; } known[] = {
        {  1, "malloc" },      {  2, "malloc_small" }, {  3, "malloc_large" },
        {  4, "malloc_huge" }, {  7, "malloc_tiny" },  { 11, "malloc_nano" },
        { 21, "IOKit" },       { 30, "stack" },        { 33, "dylib" },
        { 44, "java" },        { 57, "IOSurface" },    { 63, "accelerate" },
    };

    typedef struct { unsigned tag; uint64_t dirty; } Bucket;
    Bucket buckets[128] = {0};
    int count = 0;
    uint64_t total = 0;

    // ⚠️ `mach_vm_*` 는 iOS SDK 에서 막혀 있다(mach_vm.h: "unsupported").
    //    64비트 정보를 주는 `vm_region_recurse_64` 는 쓸 수 있다.
    vm_address_t address = 0;
    // ⚠️ `depth` 는 루프 **밖**에 있어야 한다. 안에 두고 매번 0 으로 되돌리면,
    //    서브맵(공유 캐시)을 만나는 순간 같은 주소를 끝없이 재조회하다 가드에 걸려
    //    멈춘다 — 그 뒤 영역(JVM 힙·GL 버퍼)은 통째로 못 본다.
    //    실제로 그래서 2835 MB 중 938 MB 만 보였다.
    natural_t depth = 0;
    for (int guard = 0; guard < 200000; guard++) {
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &address, &size,
                                                &depth, (vm_region_recurse_info_64_t)&info,
                                                &infoCount);
        if (kr != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }   // 같은 주소에서 한 단계 내려간다

        // 더티 + 스왑(압축)만 센다. 클린 상주는 파일 기반이라 언제든 버려져서
        // jetsam 이 보는 phys_footprint 에 들어가지 않는다.
        uint64_t dirty = (uint64_t)(info.pages_dirtied + info.pages_swapped_out) * PAGE_SIZE;
        if (dirty > 0) {
            total += dirty;
            int slot = -1;
            for (int i = 0; i < count; i++) if (buckets[i].tag == info.user_tag) { slot = i; break; }
            if (slot < 0 && count < (int)(sizeof(buckets) / sizeof(buckets[0]))) {
                slot = count++;
                buckets[slot].tag = info.user_tag;
            }
            if (slot >= 0) buckets[slot].dirty += dirty;
        }
        address += size;
    }

    // 큰 것부터 여덟 개만. 나머지는 봐야 의미가 없다.
    for (int i = 0; i < count; i++) {
        for (int j = i + 1; j < count; j++) {
            if (buckets[j].dirty > buckets[i].dirty) {
                Bucket t = buckets[i]; buckets[i] = buckets[j]; buckets[j] = t;
            }
        }
    }
    // ⚠️ 태그별 합계는 어디까지나 우리가 훑어 더한 값이다. jetsam 이 실제로 보는 건
    //    phys_footprint 이고, 커널이 그 내역을 직접 준다. 둘을 나란히 찍어 두면
    //    "우리가 못 본 부분"이 얼마인지 바로 드러난다.
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &vmCount) == KERN_SUCCESS) {
        printf("[FlameVM] footprint %llu MB = 익명 %llu + 압축 %llu · "
               "파일기반 %llu · 재사용가능 %llu · 폐기가능 %llu\n",
               (unsigned long long)(vmInfo.phys_footprint >> 20),
               (unsigned long long)(vmInfo.internal >> 20),
               (unsigned long long)(vmInfo.compressed >> 20),
               (unsigned long long)(vmInfo.external >> 20),
               (unsigned long long)(vmInfo.reusable >> 20),
               (unsigned long long)(vmInfo.purgeable_volatile_resident >> 20));
    }
    printf("[FlameVM] 훑어서 더한 값 %llu MB — 태그별 상위:\n", total >> 20);
    for (int i = 0; i < count && i < 8; i++) {
        const char *name = NULL;
        for (size_t k = 0; k < sizeof(known) / sizeof(known[0]); k++) {
            if (known[k].tag == buckets[i].tag) { name = known[k].name; break; }
        }
        printf("[FlameVM]   %-14s (tag %3u) %5llu MB\n",
               name ? name : "?", buckets[i].tag, buckets[i].dirty >> 20);
    }
    fflush(stdout);
}

static void flame_startMemoryWatch(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int lowest = INT_MAX;
        int seconds = 0;
        int lastFrames = -1;
        int stalledSeconds = 0;
        BOOL dumped = NO;
        while (1) {
            int available = FlameNativeAvailableMemoryMB();
            int used = FlameNativeMemoryFootprintMB();
            if (available >= 0 && available < lowest) lowest = available;

            // 위험 구간에 들어오면 몇 번만 태그별 내역을 남긴다. 죽고 나면 못 본다.
            static int vmDumpsLeft = 3;
            if (vmDumpsLeft > 0 && available >= 0 && available < 400) {
                vmDumpsLeft--;
                flame_dumpMemoryRegions();
            }

            // ⚠️ 여기서 `malloc_zone_pressure_relief` 를 불러 봤지만 **아무것도 안 돌아왔다**
            //    (malloc_small 782 MB → 781 MB). 즉 그 782 MB 는 해제됐는데 malloc 이
            //    쥐고 있는 게 아니라 **살아 있는 할당**이다.
            //    정체: 마인크래프트는 스티칭이 끝나도 스프라이트마다 원본 NativeImage 를
            //    `SpriteContents` 안에 계속 들고 있다(애니메이션·getPixels 때문). 서버
            //    리소스팩의 텍스처 수천 장이 각 16~64 KB 로 malloc_small 에 남는 것이다.
            //    프로세스 안에서 줄일 방법이 없다 — 팩을 안 받는 것 말고는.
            // 파일 기반으로 빼돌린 양을 같이 찍는다 — 할당자가 실제로 얼마나
            // 일하고 있는지는 이 숫자로만 알 수 있다(footprint 에는 안 잡히므로).
            printf("[FlameMem] 사용 %d MB · 남은 여유 %d MB (최저 %d MB) · 파일매핑 %llu MB\n",
                   used, available, lowest == INT_MAX ? -1 : lowest,
                   (unsigned long long)(flame_alloc_mapped_bytes() >> 20));
            fflush(stdout);

            // ⚠️ 예전 조건은 "첫 프레임이 아직 없을 때" 였는데, 마인크래프트는 로딩 화면을
            //    거의 바로 그리기 시작하므로 **사실상 절대 발동하지 않았다**.
            //    멈춤은 "첫 프레임이 없는 것"이 아니라 "프레임이 더 안 나오는 것"이다.
            seconds += 2;
            int frames = atomic_load_explicit(&flameFrameCount, memory_order_relaxed);
            if (frames != lastFrames) {
                lastFrames = frames;
                stalledSeconds = 0;
            } else if (flameHasRendered || seconds >= 120) {
                stalledSeconds += 2;
            }

            if (!dumped && stalledSeconds >= 90) {
                dumped = YES;
                printf("[FlameDump] %d초째 새 프레임이 없습니다 — 스택을 남깁니다\n",
                       stalledSeconds);
                fflush(stdout);
                flame_dumpNativeStacks();   // 감시 스레드에서 바로 — 메인을 막지 않는다
            }
            sleep(2);
        }
    });
}

// MARK: - 상태 조회

bool FlameNativeIsGrabbing(void) { return isGrabbing == JNI_TRUE; }
bool FlameNativeHasRendered(void) { return flameHasRendered; }

int FlameNativeCurrentFPS(void) {
    static int lastCount = 0;
    static CFTimeInterval lastTime = 0;
    static int cached = -1;

    if (!flameHasRendered) return -1;

    CFTimeInterval now = CACurrentMediaTime();
    int count = atomic_load_explicit(&flameFrameCount, memory_order_relaxed);
    if (lastTime == 0) {
        lastTime = now;
        lastCount = count;
        return cached;
    }
    CFTimeInterval elapsed = now - lastTime;
    if (elapsed >= 1.0) {
        cached = (int)((count - lastCount) / elapsed);
        lastTime = now;
        lastCount = count;
    }
    return cached;
}

// MARK: - 입력 주입

void FlameNativeSendKey(int key, int scancode, int action, int mods) {
    CallbackBridge_nativeSendKey(key, scancode, action, mods);
}

void FlameNativeSendChar(unsigned int codepoint) {
    CallbackBridge_nativeSendChar((jchar)codepoint);
}

void FlameNativeSendMouseButton(int button, int action, int mods) {
    CallbackBridge_nativeSendMouseButton(button, action, mods);
}

void FlameNativeSendCursorPos(int mode, double x, double y) {
    // mode 0 = 절대좌표(메뉴/인벤토리), 1 = 상대델타(인게임 시점 회전)
    CallbackBridge_nativeSendCursorPos(mode == 0 ? ACTION_DOWN : ACTION_MOVE_MOTION, x, y);
}

void FlameNativeSendScroll(double dx, double dy) {
    CallbackBridge_nativeSendScroll(dx, dy);
}

void FlameNativePauseGame(void) { CallbackBridge_pauseGameIfNeed(); }

// MARK: - 기본 환경변수

static void init_loadDefaultEnv(void) {
    // ⭐️ 패치된 org.lwjgl.glfw.GLFW 가 이 경로로 **앱 실행 파일을 dlopen** 한다:
    //      System.load(System.getenv("BUNDLE_PATH") + "/FlameLauncher");
    //    iOS 에는 libglfw.dylib 이 없다 — GLFW 구현이 앱 바이너리 안에 있기 때문이다.
    //    이 변수가 없으면 GLFW 초기화가 UnsatisfiedLinkError 로 죽는다.
    setenv("BUNDLE_PATH", NSBundle.mainBundle.bundlePath.UTF8String, 1);

    // Caciocavallo 가 안드로이드 전용 라이브러리를 찾다 NPE 를 내는 것을 막는다.
    setenv("LD_LIBRARY_PATH", "", 1);

    // 1.17+ 의 오버로드 함수 해킹 비활성 (GL4ES)
    setenv("LIBGL_NOINTOVLHACK", "1", 1);

    // GL4ES 1.1.5 이후 배너·양 색이 하얗게 나오는 문제 회피
    setenv("LIBGL_NORMALIZE", "1", 1);

    // Zink 용 OpenGL 버전 오버라이드
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);

    // JVM 은 전용 스레드에서 돌린다 — iOS 의 메인 스레드는 UIKit 것이라 내줄 수 없다.
    // (인자에서도 -XstartOnFirstThread 를 빼뒀다. 이 변수는 그래도 남겨둔다 —
    //  JRE 빌드에 따라 최초-스레드 요구를 무시하는 패치가 이 이름을 본다)
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);
}

// MARK: - JVM 부팅

/// stdout/stderr 를 Documents/latestlog.txt 로 돌린다. 게임 로그와 JVM 진단이 여기 쌓인다.
static void flame_redirectStdio(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/latestlog.txt"];

    // ⚠️ 직전 실행분을 한 세대 남긴다. 예전엔 그냥 덮어써서, 버전 A 가 죽은 뒤 B 를
    //    띄우면 A 의 증거가 사라졌다 — 스택을 번갈아 시험할 때(3.3.3 ↔ 3.4.1)
    //    죽은 쪽 로그를 볼 방법이 없어진다.
    NSString *prev = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/prevlog.txt"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:path]) {
        [fm removeItemAtPath:prev error:NULL];
        [fm moveItemAtPath:path toPath:prev error:NULL];
    }

    int fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        NSLog(@"[FlameLauncher] 로그 파일을 열지 못했습니다: %s", strerror(errno));
        return;
    }
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    close(fd);
    // 크래시로 죽어도 지금까지 쓴 게 남아야 한다 — 버퍼링을 끈다.
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    NSLog(@"[FlameLauncher] 로그를 %@ 로 돌립니다", path);
}

/// `brk #0x69` 를 걸어 JIT 스크립트가 응답하는지 본다.
///
/// 스크립트가 붙어 있으면 디버거가 트랩을 가로채 값을 돌려준다. 없으면 SIGTRAP 이
/// 우리에게 오는데, 기본 동작은 프로세스 종료다 — 그러면 "실행하자마자 튕김" 이 된다.
/// 그래서 잠깐 핸들러를 걸어 두고 빠져나온다.
static sigjmp_buf flameTrapJump;
static volatile sig_atomic_t flameTrapArmed = 0;

static void flame_trapHandler(int sig) {
    if (!flameTrapArmed) return;
    flameTrapArmed = 0;
    siglongjmp(flameTrapJump, 1);
}

static void *flame_probeJITScript(void) {
    struct sigaction previous;
    struct sigaction handler = {0};
    handler.sa_handler = flame_trapHandler;
    sigemptyset(&handler.sa_mask);
    sigaction(SIGTRAP, &handler, &previous);

    void *result = NULL;
    flameTrapArmed = 1;
    if (sigsetjmp(flameTrapJump, 1) == 0) {
        result = JIT26CreateRegionLegacy(getpagesize());
    } else {
        printf("[JIT26] brk 를 받아줄 스크립트가 없습니다\n");
        result = NULL;
    }
    flameTrapArmed = 0;

    sigaction(SIGTRAP, &previous, NULL);
    return result;
}

// MARK: - 게임 종료 가로채기

/// 마인크래프트의 "게임 종료" 는 결국 `System.exit` → C 의 `exit()` 로 내려온다.
/// 그대로 두면 **앱이 통째로 끝난다**. 우리는 런처 화면으로 돌아가고 싶으므로 가로챈다.
///
/// ⚠️ 이 함수는 **돌아가지 않는다.** 호출한 쪽(JVM 종료 경로)은 반환을 기대하지 않고,
///    돌려보내면 이미 정리된 상태에서 계속 돌다 죽는다. 그래서 이 스레드는 여기서 멈춘다.
///    JVM 은 이 시점에 이미 월드 저장을 끝냈다.
///    (JLI_Launch 는 프로세스당 한 번뿐이라 어차피 이 JVM 은 다시 못 쓴다)
NSString *const FlameGameDidExitNotification = @"FlameGameDidExit";

static void (*flame_orig_exit)(int);

static void flame_hooked_exit(int code) {
    printf("[FlameLauncher] 게임이 exit(%d) 를 호출했습니다 — 런처로 돌아갑니다\n", code);
    fflush(stdout);

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FlameGameDidExitNotification
                                                          object:@(code)];
    });

    while (1) { sleep(3600); }
}

// MARK: - DNS

/// iOS 에는 읽을 수 있는 `/etc/resolv.conf` 가 없다.
///
/// 자바의 DNS(JNDI)는 그 파일에서 네임서버를 읽는데, 없으면 조회가 통째로 실패한다.
/// 마인크래프트는 서버 주소를 붙일 때 **SRV 레코드**(`_minecraft._tcp.<도메인>`)를 먼저
/// 찾아 실제 포트를 알아내므로, 조회가 실패하면 기본 포트 25565 로 붙는다 —
/// SRV 로 다른 포트를 쓰는 서버는 "Connection refused" 가 된다.
/// 그래서 우리가 파일을 하나 만들어 두고, 그 경로를 열려는 시도를 가로채 돌려준다.
static NSString *flameResolvConfPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/resolv.conf"];
        NSString *contents = @"nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\n";
        [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
    return path;
}

static int (*flame_orig_open)(const char *, int, ...);

/// ⚠️ `open` 은 **가변 인자 함수**다. 세 번째 인자를 고정 매개변수로 선언하면 안 된다 —
///    arm64 에서 가변 인자는 스택으로 오는데 고정 매개변수는 레지스터에서 읽으므로
///    쓰레기 값이 들어간다. 그러면 O_CREAT 로 만든 파일이 권한 000 이 되어,
///    나중에 그 파일을 열 때 "Permission denied" 가 난다
///    (서버 리소스팩이 받아지고도 적용이 안 되던 원인).
static int flame_hooked_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = (mode_t)va_arg(args, int);   // 가변 인자에서 int 로 승격돼 온다
        va_end(args);
    }

    if (path && strcmp(path, "/etc/resolv.conf") == 0) {
        path = flameResolvConfPath().UTF8String;
    }
    return (oflag & O_CREAT) ? flame_orig_open(path, oflag, mode)
                             : flame_orig_open(path, oflag);
}

// MARK: - realpath (샌드박스 우회)

/// `path` 를 **파일시스템을 건드리지 않고** 정규화한다 — `.` 을 버리고 `..` 을 되감는다.
/// (자바의 `toAbsolutePath().normalize()` 와 같은 의미다. 심볼릭 링크는 풀지 않는다.)
///
/// 결과는 `out` 에 쓴다. `out` 은 PATH_MAX 이상이어야 한다.
void FlameNativeLexicalRealpath(const char *path, char *out) {
    if (!path || !out) return;

    char absolute[PATH_MAX * 2];
    if (path[0] == '/') {
        snprintf(absolute, sizeof(absolute), "%s", path);
    } else {
        char cwd[PATH_MAX];
        if (!getcwd(cwd, sizeof(cwd))) cwd[0] = '\0';
        snprintf(absolute, sizeof(absolute), "%s/%s", cwd, path);
    }

    // 구간을 훑으면서 스택처럼 쌓는다. `..` 은 직전 구간을 지운다.
    const char *segments[PATH_MAX / 2];
    size_t lengths[PATH_MAX / 2];
    size_t count = 0;

    const char *cursor = absolute;
    while (*cursor) {
        while (*cursor == '/') cursor++;
        if (!*cursor) break;
        const char *start = cursor;
        while (*cursor && *cursor != '/') cursor++;
        size_t length = (size_t)(cursor - start);

        if (length == 1 && start[0] == '.') continue;
        if (length == 2 && start[0] == '.' && start[1] == '.') {
            if (count > 0) count--;          // 루트 위로는 못 올라간다
            continue;
        }
        if (count < sizeof(segments) / sizeof(segments[0])) {
            segments[count] = start;
            lengths[count] = length;
            count++;
        }
    }

    if (count == 0) { strcpy(out, "/"); return; }

    size_t written = 0;
    for (size_t i = 0; i < count; i++) {
        if (written + lengths[i] + 2 > PATH_MAX) break;
        out[written++] = '/';
        memcpy(out + written, segments[i], lengths[i]);
        written += lengths[i];
    }
    out[written] = '\0';
}

static char *(*flame_orig_realpath)(const char *, char *);

/// ⚠️ iOS 샌드박스는 `/private` 와 `/var` 를 **stat 조차 못 하게** 막는다. 그래서
///    `realpath(3)` 은 우리 앱 폴더 안의 멀쩡한 경로에도 EPERM 을 돌려준다. 그 결과
///    자바의 `Path.toRealPath()` 가 **항상** 실패한다 — 이걸 쓰는 모드
///    (Cobblemon 의 Graal 샌드박스 등)는 그대로 멈춰 선다.
///
///    실패가 **권한 때문일 때만** 링크를 풀지 않은 정규화 결과로 대신한다.
///    ENOENT(진짜 없는 경로)는 그대로 돌려줘야 한다 — 존재 확인용으로 realpath 를
///    쓰는 코드가 있어서, 여기서 없는 경로를 지어내면 그쪽이 조용히 망가진다.
static char *flame_hooked_realpath(const char *path, char *resolved) {
    char *result = flame_orig_realpath(path, resolved);
    if (result) return result;
    if (errno != EPERM && errno != EACCES) return NULL;

    char lexical[PATH_MAX];
    FlameNativeLexicalRealpath(path, lexical);

    static BOOL announced = NO;
    if (!announced) {
        announced = YES;
        printf("[FlameLauncher] realpath 가 샌드박스에 막혀 정규화로 대신합니다 (%s → %s)\n",
               path ? path : "(null)", lexical);
    }

    // resolved 가 NULL 이면 호출자가 free 한다는 뜻이다(POSIX).
    char *out = resolved ? resolved : malloc(PATH_MAX);
    if (!out) return NULL;
    strlcpy(out, lexical, PATH_MAX);
    errno = 0;
    return out;
}

static void flame_installHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    flameResolvConfPath();   // 가로채기 전에 파일부터 만들어 둔다
    struct rebinding rebindings[] = {
        { "exit", flame_hooked_exit, (void *)&flame_orig_exit },
        { "open", flame_hooked_open, (void *)&flame_orig_open },
        // ⚠️ libnio 가 실제로 가져다 쓰는 이름은 `realpath$DARWIN_EXTSN` 이다
        //    (nm -u libnio.dylib 로 확인). 평범한 `realpath` 만 걸면 안 걸린다.
        { "realpath$DARWIN_EXTSN", flame_hooked_realpath, (void *)&flame_orig_realpath },
        { "realpath", flame_hooked_realpath, (void *)&flame_orig_realpath },
    };
    rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
}

int FlameNativeLaunchJVM(const char *javaHome, const char *_Nonnull *_Nonnull argv, int argc) {
    @autoreleasepool {

        // ⚠️ 시뮬레이터에서는 절대 시도하면 안 된다.
        //    번들 JRE 와 렌더러는 전부 **기기용 arm64(iOS 플랫폼)** 바이너리다. 시뮬레이터는
        //    iOS-Simulator 플랫폼이라 dlopen 하는 순간 코드서명 검증에 걸려 프로세스가
        //    SIGKILL(CODESIGNING / Invalid Page) 로 죽는다 — 잡을 수 있는 예외가 아니다.
        if (getenv("SIMULATOR_DEVICE_NAME")) {
            NSLog(@"[FlameLauncher] 시뮬레이터에서는 JVM 을 띄울 수 없습니다");
            return FLAME_LAUNCH_ERR_SIMULATOR;
        }

        // ⚠️ stdout/stderr 를 파일로 받아둔다. StikDebug 의 debugserver 가 붙어 있으면
        //    NSLog 도 libjvm 의 printf 도 통합 로그에 안 남는다 — 디버거가 가져간다.
        //    ⚠️ 그래서 이 함수 안의 진단은 전부 printf 로 찍는다. NSLog 로 찍으면
        //       리다이렉트한 파일에 안 남아서 "로그가 0바이트" 인 상태로만 보인다.
        //    libjvm 이 "[JIT26] Got JIT mapping ... from debugger" 같은 결정적인 줄을
        //    stdout 에 찍으므로, 이게 없으면 왜 실패했는지 알 방법이 없다.
        flame_redirectStdio();

        // ⚠️ 첫 줄은 **리다이렉트 뒤에** 찍는다. 예전에는 이 함수 맨 앞에서 찍었는데,
        //    그때 stdout 은 아직 버퍼링 상태라 줄이 버퍼에만 들어간다. 그 뒤 어디서든
        //    죽으면 파일에 아무것도 안 남아 "로그 0바이트" 하나만 보이고 끝이다.
        //    (이 파일의 다른 주석이 경고하던 바로 그 상황이다)
        printf("[FlameLauncher] JVM 부팅 시작 (JAVA_HOME=%s)\n", javaHome);
        fflush(stdout);

        // 게임 종료 가로채기 + /etc/resolv.conf 대체.
        printf("[FlameLauncher] 훅 설치\n"); fflush(stdout);
        flame_installHooks();
        printf("[FlameLauncher] 메모리 감시 시작\n"); fflush(stdout);
        flame_startMemoryWatch();

        init_loadDefaultEnv();
        setenv("JAVA_HOME", javaHome, 1);

        // ── iOS 26 디버거 보조 JIT (JIT26) ──────────────────────────────────
        // 번들 libjvm 은 이 규약으로 패치돼 있다. TXM 기기에서는 JVM 이 코드 캐시를
        // 직접 못 잡고 `brk #0x69` 로 디버거에게 RX 영역을 얻어온다.
        // 자세한 배경은 flame_jit26.m 참고.
        FlameNativeGetJITFlags(YES);   // 환경변수를 다 읽은 뒤에 다시 계산한다
        BOOL requiresTXMWorkaround =
            FlameNativeHasJITFlags(FlameJITFlagForceMirrored | FlameJITFlagHasTXM);

        if (requiresTXMWorkaround) {
            // ⚠️ 디버거가 없는데 brk 를 걸면 잡을 사람이 없어 SIGTRAP 으로 즉사한다.
            //    반드시 먼저 확인한다.
            if (!JIT26IsLikelyDebuggerKeepAttached()) {
                printf("[JIT26] 디버거가 붙어 있지 않습니다 — StikDebug 으로 실행해야 합니다\n");
                return FLAME_LAUNCH_ERR_NO_DEBUGGER;
            }

            // 스크립트가 붙었는지 JVM 과 **같은 경로**로 확인한다.
            // Universal 스크립트는 legacy 0x69 에 0x690000E0 을 돌려주도록 돼 있다.
            //
            // ⚠️ 스크립트가 없으면 `brk` 를 받아줄 사람이 없어 SIGTRAP 으로 **즉사**한다.
            //    (StikDebug 을 붙였어도 스크립트를 지정 안 했으면 그렇다 — 앱을 다시 설치하면
            //     지정이 풀린다.) 여기서 잡아 안내로 바꾼다.
            void *probe = flame_probeJITScript();
            if ((uint32_t)(uintptr_t)probe != 0x690000E0) {
                printf("[JIT26] JIT 스크립트가 응답하지 않습니다 (probe=%p)\n", probe);
                return FLAME_LAUNCH_ERR_JIT_SCRIPT;
            }

            // JVM 이 쓰는 brk #0x69 핸들러를 심는다. 이걸 안 보내면 기본 스크립트가
            // 계속 0x690000E0(에러)만 돌려줘서 JVM 이 매핑을 못 받는다.
            NSString *extPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension"
                                                              ofType:@"js"];
            NSString *ext = extPath ? [NSString stringWithContentsOfFile:extPath
                                                               encoding:NSUTF8StringEncoding
                                                                  error:nil] : nil;
            if (!ext.length) {
                printf("[JIT26] 번들에 UniversalJIT26Extension.js 가 없습니다\n");
                return FLAME_LAUNCH_ERR_JIT_SCRIPT;
            }
            JIT26SendJITScript(ext);

            // 매핑을 받은 뒤 디버거를 떼게 한다 — 붙어 있으면 매 트랩마다 끊긴다.
            JIT26SetDetachAfterFirstBr(YES);

            // 디버거가 떨어진 뒤 EXC_BAD_ACCESS 가 아무도 안 받는 상태로 남지 않게
            // 예외 포트를 커널 기본으로 되돌린다(Amethyst 와 동일).
            task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0,
                                     EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
            printf("[JIT26] 준비 완료 — 디버거 보조 JIT 사용\n");
        }

        NSString *home = @(javaHome);
        NSFileManager *fm = NSFileManager.defaultManager;
        BOOL insideBundle = [home hasPrefix:NSBundle.mainBundle.bundlePath];

        // ⚠️ 라이브러리 검증 우회는 **번들 밖** JRE 를 열 때만 필요하다.
        //    번들 안 JRE 는 앱과 같은 신원으로 서명돼 있어서 그냥 열린다.
        //
        //    이 우회는 dyld 의 코드 페이지를 vm_protect 로 열고 mmap/fcntl 을 직접
        //    덮어쓴다. 최신 iOS 에서는 그 쓰기가 보호 위반으로 막혀
        //    EXC_BAD_ACCESS(code=2) 로 프로세스가 죽는다 — 실제로 그렇게 죽었다.
        //    그래서 정말 필요한 경우에만 부른다.
        // ⚠️ TXM 워크어라운드를 쓰는 동안에는 이 우회를 걸면 안 된다. dyld 코드 페이지를
        //    직접 덮어쓰는데, JIT26 경로에서는 그 쓰기가 디버거 트랩과 엉켜 죽는다.
        //    (Amethyst 도 requiresTXMWorkaround 일 때는 끈다)
        if (!insideBundle && !requiresTXMWorkaround) {
            NSLog(@"[FlameLauncher] 번들 밖 JRE — 라이브러리 검증 우회 시도");
            init_bypassDyldLibValidation();
        } else if (!insideBundle) {
            NSLog(@"[FlameLauncher] 번들 밖 JRE 지만 JIT26 경로라 검증 우회를 끕니다"
                  @" — 서명 안 된 dylib 은 열리지 않습니다");
        }

        // headful AWT 네이티브가 없는 JRE 를 위해 번들의 스텁을 심어둔다.
        // (cacio 가 toolkit 을 가로채도, JRE 가 파일 존재 자체를 확인하는 경로가 있다)
        NSString *xawtDest = [home stringByAppendingPathComponent:@"lib/libawt_xawt.dylib"];
        NSString *xawtSrc = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Frameworks/libawt_xawt.dylib"];
        if (![fm fileExistsAtPath:xawtDest] && [fm fileExistsAtPath:xawtSrc]) {
            [fm createSymbolicLinkAtPath:xawtDest withDestinationPath:xawtSrc error:nil];
        }

        // JRE8 은 lib/jli/, JRE9+ 는 lib/ 에 libjli 가 있다.
        NSString *jli8 = [home stringByAppendingPathComponent:@"lib/jli/libjli.dylib"];
        NSString *jli11 = [home stringByAppendingPathComponent:@"lib/libjli.dylib"];
        NSString *jliPath = [fm fileExistsAtPath:jli8] ? jli8 : jli11;

        if (![fm fileExistsAtPath:jliPath]) {
            printf("[FlameLauncher] libjli.dylib 을 찾지 못했습니다: %s\n", jliPath.UTF8String);
            return FLAME_LAUNCH_ERR_NO_JLI;
        }

        // ⚠️ 사용자가 넣은 JRE 만 플랫폼 로드 커맨드를 고친다.
        //    이 함수는 **파일을 직접 수정**하므로 앱 번들 안의 것에 쓰면 번들 서명이 깨진다.
        //    번들 JRE 는 애초에 맞는 플랫폼으로 빌드돼 있으니 손댈 필요도 없다.
        //    (PojavLauncher iOS 도 $HOME 아래 dylib 에만 이 처리를 한다)
        if (!insideBundle) {
            PLPatchMachOPlatformForFile(jliPath.UTF8String);
        }
        printf("[FlameLauncher] libjli 로드: %s\n", jliPath.UTF8String);

        void *libjli = dlopen(jliPath.UTF8String, RTLD_GLOBAL);
        if (!libjli) {
            printf("[FlameLauncher] libjli dlopen 실패: %s\n", dlerror());
            return FLAME_LAUNCH_ERR_DLOPEN;
        }

        JLI_Launch_func *pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
        if (!pJLI_Launch) {
            printf("[FlameLauncher] JLI_Launch 심볼이 없습니다\n");
            return FLAME_LAUNCH_ERR_NO_SYMBOL;
        }

        // 크래시 리포터가 먼저 잡아 JVM 이 자기 시그널을 처리하지 못하는 것을 막는다.
        signal(SIGSEGV, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
        signal(SIGILL, SIG_DFL);
        signal(SIGFPE, SIG_DFL);

        // ⚠️ argv 는 호출자(Swift)가 이 함수가 끝나면 해제한다. JLI 는 별도 스레드에서
        //    이 배열을 계속 쓰므로 깊은 복사로 우리가 소유한다.
        flameSavedArgv = calloc(argc + 1, sizeof(char *));
        for (int i = 0; i < argc; i++) flameSavedArgv[i] = strdup(argv[i]);
        flameSavedArgc = argc;
        flameSavedJLILaunch = (void *)pJLI_Launch;

        // 부팅이 실패하면 어떤 인자로 들어갔는지가 유일한 단서다.
        // ⚠️ NSLog 로 찍으면 안 된다 — 디버거가 붙어 있으면 stderr 를 가져가서
        //    리다이렉트한 로그 파일에 안 남는다. printf 는 남는다([JIT26] 줄과 같은 이유).
        printf("[FlameLauncher] JLI_Launch 호출 (argc=%d)\n", argc);
        for (int i = 0; i < argc; i++) printf("  [%d] %s\n", i, argv[i]);

        // ⚠️ 프로세스 시작 시점의 진단은 의미가 없다 — StikDebug 은 앱이 뜬 **뒤에** 붙는다.
        //    JVM 이 코드 캐시를 실행하기 직전인 여기서 봐야 실제 상태를 안다.
        //    NSLog 는 디버거가 stderr 를 가로채면 통합 로그에 안 남으므로 파일로도 남긴다.
        // ⚠️ 마인크래프트와 일부 모드가 **상대 경로**로 파일을 연다
        //    (log4j 의 logs/latest.log, Cobblemon 의 showdown/ 등).
        //    -Duser.dir 만으로는 부족한 경우가 있어 프로세스 CWD 자체를 옮긴다.
        //    Swift 쪽에서도 한 번 하지만, 부팅 직전인 여기서 확정한다.
        for (int i = 0; i < argc; i++) {
            if (strncmp(argv[i], "-Duser.dir=", 11) != 0) continue;
            if (chdir(argv[i] + 11) != 0) {
                printf("[FlameLauncher] chdir 실패: %s (%s)\n", argv[i] + 11, strerror(errno));
            }
            break;
        }
        char cwd[PATH_MAX] = {0};
        if (getcwd(cwd, sizeof(cwd))) printf("[FlameLauncher] CWD=%s\n", cwd);

        NSString *jitState = FlameNativeJITProbe();
        printf("[FlameLauncher] 부팅 직전 JIT 상태:\n%s\n", jitState.UTF8String);
        [jitState writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jit_state.txt"]
                   atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return pJLI_Launch(argc, (char **)argv,
                           0, NULL,
                           0, NULL,
                           "1.8.0-internal", "1.8",
                           "java", "openjdk",
                           JNI_FALSE, JNI_TRUE, JNI_FALSE, JNI_TRUE);
    }
}


/// JLI 가 `apple_main` 에서 우리 진입점을 다시 부른 경우, 이 스레드에서 JVM 을 실행한다.
/// - Returns: 재진입이 아니어서 아무것도 하지 않았으면 false. true 면 돌아오지 않는다.
bool FlameNativeContinueJVM(void) {
    JLI_Launch_func *launch = (JLI_Launch_func *)flameSavedJLILaunch;
    if (!launch) return false;

    NSLog(@"[FlameLauncher] JLI 재진입 — 이 스레드에서 JVM 을 실행합니다 (argc=%d)", flameSavedArgc);
    launch(flameSavedArgc, flameSavedArgv,
           0, NULL,
           0, NULL,
           "1.8.0-internal", "1.8",
           "java", "openjdk",
           JNI_FALSE, JNI_TRUE, JNI_FALSE, JNI_TRUE);
    return true;
}
