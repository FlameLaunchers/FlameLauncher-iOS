//
//  flame_jit.m — JIT 활성화.
//  PojavLauncher iOS 의 main.m / utils.m / LauncherNavigationController.m 에 흩어져 있던
//  JIT 관련 코드를 한 파일로 모은 것.
//
//  왜 필요한가: 서명된 iOS 앱은 W^X 때문에 실행 가능한 메모리에 코드를 쓸 수 없다.
//  HotSpot 은 인터프리터 템플릿부터 런타임에 생성하므로 JIT 없이는 사실상 못 돈다.
//  커널은 **CS_DEBUGGED 플래그가 선 프로세스**에만 예외를 주고, 그 플래그는 디버거가
//  붙어야 생긴다. 아래 경로들이 전부 결국 "디버거를 붙인다"는 같은 일을 한다.
//
//    1. 이미 켜짐        — Xcode 실행 중, 또는 dynamic-codesigning 권한
//    2. 탈옥             — 플랫폼 바이너리로 취급되어 자동
//    3. no-sandbox       — 자기 자신을 자식으로 띄워 ptrace(PT_TRACE_ME)  (TrollStore/탈옥)
//    4. TrollStore JIT   — apple-magnifier://enable-jit URL 로 TrollStore 에 요청
//    5. AltServer        — 같은 Wi-Fi 의 AltStore/SideStore 서버에 붙어 요청 (AltKit)
//    6. 그 외            — StikDebug 등으로 사용자가 직접 붙일 때까지 기다린다
//
#import <UIKit/UIKit.h>
#import <objc/message.h>

#include <dirent.h>
#include <setjmp.h>
#include <signal.h>
#include <string.h>
#include <sys/mman.h>
#import <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

#include "FlameNative.h"
#include "flame_compat.h"

#define CS_DEBUGGED 0x10000000
#define CS_PLATFORM_BINARY 0x4000000
#define CS_OPS_STATUS 0
#define PT_TRACE_ME 0
#define PT_DETACH 11

int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
int ptrace(int request, pid_t pid, caddr_t addr, int data);
CFTypeRef SecTaskCopyValueForEntitlement(void *task, NSString *entitlement, CFErrorRef _Nullable *error);
void *SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern char **environ;

// MARK: - 엔타이틀먼트

BOOL FlameNativeHasEntitlement(NSString *key) {
    void *secTask = SecTaskCreateFromSelf(NULL);
    if (!secTask) return NO;
    CFTypeRef value = SecTaskCopyValueForEntitlement(secTask, key, nil);
    BOOL result = value != nil && [(__bridge id)value boolValue];
    if (value) CFRelease(value);
    CFRelease(secTask);
    return result;
}

// MARK: - 탈옥 판정

/// Substrate 의 데몬이 떠 있는지. 탈옥 판정 중 가장 확실한 신호다.
static bool checkForSubstrated(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return false;

    struct kinfo_proc *processes = NULL;
    int st;
    do {
        size += size / 10;
        struct kinfo_proc *grown = realloc(processes, size);
        if (!grown) { free(processes); return false; }
        processes = grown;
        st = sysctl(mib, 4, processes, &size, NULL, 0);
    } while (st == -1 && errno == ENOMEM);

    bool found = false;
    if (st == 0 && size % sizeof(struct kinfo_proc) == 0) {
        int count = (int)(size / sizeof(struct kinfo_proc));
        for (int i = count - 1; i >= 0 && !found; i--) {
            found = strcmp(processes[i].kp_proc.p_comm, "substrated") == 0;
        }
    }
    free(processes);
    return found;
}

bool FlameNativeIsJailbroken(void) {
    static bool cached, computed;
    if (computed) return cached;
    computed = true;

    // macOS(Catalyst)는 JIT 를 자동으로 주지 않으므로 탈옥으로 치지 않는다.
    if (NSProcessInfo.processInfo.macCatalystApp) return (cached = false);
    // ⚠️ 시뮬레이터는 호스트 맥의 /Applications 가 보여서 아래 마지막 검사를 통과해 버린다.
    //    탈옥이 아니므로 여기서 잘라낸다(JIT 자체는 시뮬레이터에서 원래 제한이 없다).
    if (getenv("SIMULATOR_DEVICE_NAME")) return (cached = false);
    if (checkForSubstrated()) return (cached = true);

    // posix_spawn 이 후킹돼 있는지
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), "/usr/lib/pspawn_payload-stg2.dylib") == 0) {
            return (cached = true);
        }
    }

    // 플랫폼 바이너리 비트가 서 있으면 커널이 이미 우리를 시스템 코드로 본다
    uint32_t flags = 0;
    csops(0, CS_OPS_STATUS, &flags, sizeof(flags));
    if ((flags & CS_PLATFORM_BINARY) != 0) return (cached = true);

    // 샌드박스가 살아 있으면 /Applications 를 못 연다
    DIR *dir = opendir("/Applications");
    if (dir) { closedir(dir); return (cached = true); }
    return (cached = false);
}

// MARK: - 실제 실행 가능 여부

// ⚠️ `csops` 의 CS_DEBUGGED 만 보고 "JIT 켜짐" 이라고 단정하면 안 된다.
//    iOS 26 에서 실측해 보니 플래그는 서 있는데 커널이 실행 권한을 주지 않는 경우가 있고,
//    그 상태로 JVM 을 띄우면 첫 생성 코드에서 SIGBUS 로 죽는다.
//
// ⚠️⚠️ 그렇다고 **실행을 시도해서 확인하면 안 된다.**
//    실행이 막힌 페이지로 점프하면 iOS 26 은 잡을 수 없는 SIGKILL
//    (CODESIGNING / "Invalid Page") 로 프로세스를 즉시 죽인다.
//    sigsetjmp + SIGBUS/SIGSEGV/SIGILL 핸들러로도 못 막는다 — 실측으로 확인했고,
//    그 확인 코드 자체가 앱을 시작조차 못 하게 만들었다.
//
//    그래서 여기서는 **실행하지 않고** 알 수 있는 것만 본다.

/// JIT 전용 메모리(MAP_JIT)를 확보할 수 있는지. 실행은 시도하지 않는다.
///
/// MAP_JIT 은 `dynamic-codesigning` 권한이 있어야 성공한다(TrollStore / 탈옥).
/// 성공하면 JIT 가 확실히 동작하고, 실패해도 CS_DEBUGGED 경로가 남아 있을 수 있다.
/// ⚠️ 캐시하지 않는다. StikDebug 은 앱이 **뜬 뒤에** 붙어서 CS_DEBUGGED 를 세우므로,
///    앱 시작 때 한 번 재본 값을 들고 있으면 영영 "불가" 로 굳는다(실제로 그랬다).
///    한 페이지 mmap/munmap 이라 매번 재도 싸다.
bool FlameNativeCanAllocateJITMemory(void) {
    size_t len = (size_t)getpagesize();
    void *page = mmap(NULL, len, PROT_READ | PROT_WRITE | PROT_EXEC,
                      MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (page == MAP_FAILED) return false;
    munmap(page, len);
    return true;
}

/// 커널이 **실제로 내준 권한**을 확인한다.
///
/// mmap 이 성공해도 iOS 가 EXEC 비트를 조용히 떼는 경우가 있어서, 성공/실패만으로는
/// JIT 가 되는지 알 수 없다. vm_region 으로 부여된 보호를 직접 읽는다.
///
/// ⚠️ 절대 실행해 보지 말 것. 실행이 막힌 페이지를 건드리면 iOS 가 잡을 수 없는
///    SIGKILL(CODESIGNING, Invalid Page)로 앱을 죽인다 — 시도 자체가 진단을 망친다.
/// 현재 권한과 **최대 권한**을 함께 읽는다. cur 에서 X 가 빠져도 max 에 X 가 살아 있으면
/// vm_protect 로 올릴 여지가 남는다 — 그 차이가 진단의 핵심이다.
static NSString *flame_grantedProt(void *page) {
    vm_address_t addr = (vm_address_t)page;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS) {
        return @"조회실패";
    }
    return [NSString stringWithFormat:@"cur=%c%c%c max=%c%c%c",
            (info.protection     & VM_PROT_READ)    ? 'r' : '-',
            (info.protection     & VM_PROT_WRITE)   ? 'w' : '-',
            (info.protection     & VM_PROT_EXECUTE) ? 'x' : '-',
            (info.max_protection & VM_PROT_READ)    ? 'r' : '-',
            (info.max_protection & VM_PROT_WRITE)   ? 'w' : '-',
            (info.max_protection & VM_PROT_EXECUTE) ? 'x' : '-'];
}

static NSString *flame_probeMapping(NSString *label, int prot, int flags) {
    size_t len = (size_t)getpagesize();
    void *page = mmap(NULL, len, prot, flags, -1, 0);
    if (page == MAP_FAILED) {
        return [NSString stringWithFormat:@"%@ = 매핑실패(errno %d)", label, errno];
    }
    NSString *granted = flame_grantedProt(page);
    munmap(page, len);
    return [NSString stringWithFormat:@"%@ = 성공 %@", label, granted];
}

/// RW 로 잡아 코드를 써넣은 뒤 실행 권한으로 넘기는 W^X 전환.
static NSString *flame_probeFlip(NSString *label, int newProt) {
    size_t len = (size_t)getpagesize();
    void *page = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (page == MAP_FAILED) {
        return [NSString stringWithFormat:@"%@ = RW 매핑부터 실패(errno %d)", label, errno];
    }
    *(uint32_t *)page = 0xd65f03c0;   // ret. 실행은 절대 하지 않는다.

    NSString *result;
    if (mprotect(page, len, newProt) != 0) {
        result = [NSString stringWithFormat:@"%@ = mprotect 실패(errno %d)", label, errno];
    } else {
        result = [NSString stringWithFormat:@"%@ = 성공 %@", label, flame_grantedProt(page)];
    }
    munmap(page, len);
    return result;
}

/// ⭐️ 핵심 검사: rwx 로 매핑하면 cur 은 깎여도 max=rwx 가 남는다.
///    그 상태에서 코드를 써넣고 mprotect 로 X 를 올리면 커널이 받아주는가?
///    받아주면 HotSpot 코드 캐시를 살릴 수 있다.
static NSString *flame_probeRWXThenFlip(NSString *label, bool writeCode, int newProt) {
    size_t len = (size_t)getpagesize();
    void *page = mmap(NULL, len, PROT_READ | PROT_WRITE | PROT_EXEC,
                      MAP_PRIVATE | MAP_ANON, -1, 0);
    if (page == MAP_FAILED) {
        return [NSString stringWithFormat:@"%@ = rwx 매핑부터 실패(errno %d)", label, errno];
    }
    if (writeCode) *(uint32_t *)page = 0xd65f03c0;   // ret. 실행은 하지 않는다.

    NSString *result;
    if (mprotect(page, len, newProt) != 0) {
        result = [NSString stringWithFormat:@"%@ = mprotect 실패(errno %d)", label, errno];
    } else {
        result = [NSString stringWithFormat:@"%@ = 성공 %@", label, flame_grantedProt(page)];
    }
    munmap(page, len);
    return result;
}

/// iOS JIT 의 고전적 경로: vm_allocate 로 잡고 **최대 권한부터** VM_PROT_ALL 로 올린 뒤
/// 현재 권한을 RX 로 넘긴다. mprotect 로는 max 를 못 올리지만 vm_protect 는 올릴 수 있다.
static NSString *flame_probeVMProtect(void) {
    // iOS SDK 는 mach_vm.h 를 막아놨다 — 같은 일을 하는 vm_* 를 쓴다.
    vm_size_t len = (vm_size_t)getpagesize();
    vm_address_t addr = 0;
    kern_return_t kr = vm_allocate(mach_task_self(), &addr, len, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        return [NSString stringWithFormat:@"vm_allocate 경로 = 할당실패(kr %d)", kr];
    }
    *(uint32_t *)(uintptr_t)addr = 0xd65f03c0;

    kern_return_t krMax = vm_protect(mach_task_self(), addr, len, TRUE, VM_PROT_ALL);
    kern_return_t krCur = vm_protect(mach_task_self(), addr, len, FALSE,
                                          VM_PROT_READ | VM_PROT_EXECUTE);
    NSString *result = [NSString stringWithFormat:
        @"vm_allocate 경로 = set_max(kr %d) set_cur(kr %d) %@",
        krMax, krCur, flame_grantedProt((void *)(uintptr_t)addr)];
    vm_deallocate(mach_task_self(), addr, len);
    return result;
}

/// 커널이 **실제로 실행 권한을 주는지**. CS_DEBUGGED 만 보면 안 되는 이유:
/// iOS 26.6 에서 실측한 결과, 디버거가 붙어 CS_DEBUGGED 가 서 있어도
/// (Xcode 로 계속 붙여둬도, StikDebug 으로 켜도) 커널은 X 비트를 내주지 않는다.
///   • mmap(MAP_JIT)      → EPERM (dynamic-codesigning 권한이 있어야 한다)
///   • mmap(rwx)          → cur=rw- 로 깎임 (max 에만 x 가 남는다)
///   • 쓴 뒤 mprotect(rx) → cur=r--, max 에서도 x 가 사라진다
/// 그래서 "켜짐" 이라고 보고하면 JVM 이 코드 캐시를 실행하다 SIGBUS 로 죽는다.
///
/// ⚠️ 실행해 보는 방식으로 확인하면 안 된다 — 막힌 페이지를 실행하면 iOS 가
///    잡을 수 없는 SIGKILL(CODESIGNING) 로 죽인다. 부여된 권한만 읽는다.
bool FlameNativeHasExecutableMemory(void) {
    // 1) 프로세스가 직접 RX 를 만들 수 있으면 그걸로 끝.
    //    ⚠️ MAP_SHARED 로 재야 한다 — MAP_PRIVATE 는 iOS 가 무조건 x 를 떼서 항상 실패다.
    if (DeviceCanCreateRXMap()) return true;
    // 2) 못 만들어도 디버거가 붙어 있으면 디버거가 대신 잡아준다(JIT26).
    return JIT26IsLikelyDebuggerKeepAttached();
}

NSString *FlameNativeJITProbe(void) {
    int csflags = 0;
    csops(getpid(), CS_OPS_STATUS, &csflags, sizeof(csflags));
    FlameJITFlags jf = FlameNativeGetJITFlags(NO);
    return [@[
        [NSString stringWithFormat:@"csflags=0x%08x CS_DEBUGGED=%@", csflags,
            (csflags & CS_DEBUGGED) ? @"켜짐" : @"꺼짐"],
        // ⭐️ 여기가 갈림길이다. mirrored+TXM 이 둘 다 서야 디버거 보조 경로를 탄다.
        [NSString stringWithFormat:@"JIT 플래그=0x%lX (iOS26=%d mirrored=%d TXM=%d)",
            (unsigned long)jf,
            (jf & FlameJITFlagIsIOS26) != 0,
            (jf & FlameJITFlagForceMirrored) != 0,
            (jf & FlameJITFlagHasTXM) != 0],
        [NSString stringWithFormat:@"DeviceCanCreateRXMap(MAP_SHARED)=%@",
            DeviceCanCreateRXMap() ? @"성공 — 직접 RX 생성 가능" : @"실패"],
        [NSString stringWithFormat:@"디버거 상주(getppid)=%d → %@", getppid(),
            JIT26IsLikelyDebuggerKeepAttached() ? @"붙어있음" : @"떨어짐"],
        [NSString stringWithFormat:@"DeviceHasTXM()=%@", DeviceHasTXM() ? @"YES" : @"NO"],
        [NSString stringWithFormat:@"TXM 워크어라운드 경로=%@",
            FlameNativeHasJITFlags(FlameJITFlagForceMirrored | FlameJITFlagHasTXM)
                ? @"탄다" : @"안 탄다 ← JIT26 설정을 건너뛴다"],
        flame_probeMapping(@"mmap MAP_JIT rwx", PROT_READ | PROT_WRITE | PROT_EXEC,
                           MAP_PRIVATE | MAP_ANON | MAP_JIT),
        flame_probeMapping(@"mmap rwx PRIVATE", PROT_READ | PROT_WRITE | PROT_EXEC,
                           MAP_PRIVATE | MAP_ANON),
        flame_probeMapping(@"mmap rwx SHARED ", PROT_READ | PROT_WRITE | PROT_EXEC,
                           MAP_ANONYMOUS | MAP_SHARED),
        flame_probeFlip(@"RW→mprotect rx  ", PROT_READ | PROT_EXEC),
    ] componentsJoinedByString:@"\n"];
}

// MARK: - 상태

bool FlameNativeIsJITEnabled(void) {
    // 시뮬레이터에는 코드서명 강제 자체가 없다 — W^X 제한도 없으므로 항상 켜진 것으로 본다.
    if (getenv("SIMULATOR_DEVICE_NAME")) return true;
    if (FlameNativeHasEntitlement(@"dynamic-codesigning")) return true;
    if (FlameNativeIsJailbroken()) return true;

    int flags = 0;
    csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags));
    if ((flags & CS_DEBUGGED) == 0) return false;

    // iOS 26 + TXM 이 아니면 CS_DEBUGGED 만으로 충분하다.
    if (!FlameNativeHasJITFlags(FlameJITFlagForceMirrored | FlameJITFlagHasTXM)) return true;

    // ⚠️ 여기서는 부족하다. TXM 기기는 JVM 이 디버거에게 RX 영역을 얻어와야 하는데,
    //    CS_DEBUGGED 는 한 번 서면 디버거가 떨어져도 남는다. 지금도 붙어 있어야 한다.
    return JIT26IsLikelyDebuggerKeepAttached();
}

bool FlameNativeIsDebuggable(void) {
    // 이름이 둘로 갈린다 — 서명 방식에 따라 접두사가 붙기도 한다.
    return FlameNativeHasEntitlement(@"get-task-allow")
        || FlameNativeHasEntitlement(@"com.apple.security.get-task-allow");
}

bool FlameNativeHasTrollStoreJIT(void) {
    return FlameNativeHasEntitlement(@"com.apple.private.local.sandboxed-jit");
}

NSString *FlameNativeInstallType(void) {
    // TrollStore 는 앱 번들 옆에 마커를 남긴다.
    NSString *marker = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
    if (access(marker.UTF8String, F_OK) == 0) return @"TrollStore";
    if (FlameNativeIsJailbroken()) return @"Jailbroken";
    if (getenv("SIMULATOR_DEVICE_NAME")) return @"Simulator";
    return @"Unjailbroken";
}

// MARK: - TrollStore

bool FlameNativeRequestTrollStoreJIT(void) {
    if (!FlameNativeHasTrollStoreJIT()) return false;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    });
    return true;
}

/// StikDebug / SideStore 에게 **우리 프로세스에 붙어 JIT 를 켜 달라**고 요청한다.
///
/// ⚠️ iOS 26 + TXM 기기는 프로세스가 스스로 실행 가능 메모리를 못 얻는다. 디버거가
///    대신 할당해 주는 수밖에 없고, 그 역할을 하는 도구가 StikDebug(17.4+) / SideStore 다.
///    Amethyst 의 `invokeAfterJITEnabled:` 와 같은 규약이다.
///
/// ⭐️ `script-data` 로 `UniversalJIT26.js` 를 **같이 실어 보낸다.** 이게 핵심이다 —
///    안 보내면 사용자가 StikDebug 안에서 스크립트를 따로 지정해야 하고, 그 지정은
///    **앱을 다시 설치할 때마다 풀린다**(이 프로젝트에서 몇 번이나 겪었다).
///    실어 보내면 재설치와 무관하게 항상 같은 스크립트로 붙는다.
///
/// - Returns: 요청을 보냈으면 true. 켜졌는지는 호출자가 폴링으로 확인해야 한다.
bool FlameNativeRequestDebuggerJIT(void) {
    NSString *bundleId = NSBundle.mainBundle.bundleIdentifier;
    NSString *urlString;

    if (@available(iOS 17.4, *)) {
        NSString *scriptParam = @"";
        // 미러 경로를 타는 기기에서만 스크립트가 필요하다(그 외에는 CS_DEBUGGED 만으로 충분).
        if (FlameNativeHasJITFlags(FlameJITFlagForceMirrored | FlameJITFlagHasTXM)) {
            NSString *path = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
            NSData *script = path ? [NSData dataWithContentsOfFile:path] : nil;
            if (script) {
                NSString *encoded = [[script base64EncodedStringWithOptions:0]
                    stringByAddingPercentEncodingWithAllowedCharacters:
                        NSCharacterSet.URLQueryAllowedCharacterSet];
                scriptParam = [@"&script-data=" stringByAppendingString:encoded];
            }
        }
        urlString = [NSString stringWithFormat:
            @"stikjit://enable-jit?bundle-id=%@&pid=%d%@", bundleId, getpid(), scriptParam];
    } else {
        // 16.7 ~ 17.3. SideStore 는 bundle-id 를 받지 않고 pid 만 본다.
        urlString = [NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()];
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return false;

    // ⚠️ 예전에는 무조건 true 를 돌려줬다. 그러면 JIT 도구가 **설치돼 있지 않아도**
    //    "요청 보냈음"이 되어, 호출자는 영원히 오지 않을 CS_DEBUGGED 를 기다린다
    //    (화면에는 아무 설명 없이 스피너만 돈다).
    //    canOpenURL 은 Info.plist 의 LSApplicationQueriesSchemes 에 스킴이 있어야 답한다.
    if (![UIApplication.sharedApplication canOpenURL:url]) return false;

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    });
    return true;
}

// MARK: - AltServer (AltKit)

// AltKit 은 AltStore 가 만든 Swift 프레임워크다. **링크하지 않고** 런타임에 찾는다 —
// 기기용 arm64 바이너리라 링크하면 시뮬레이터 빌드가 통째로 깨지고, 프레임워크가 없는
// 환경에서도 앱은 정상으로 떠야 하기 때문이다.
@protocol FlameALTServerConnection <NSObject>
- (void)enableUnsignedCodeExecutionWithCompletionHandler:(void (^)(BOOL success, NSError *error))handler;
- (void)disconnect;
@end

@protocol FlameALTServerManager <NSObject>
- (void)autoconnectWithCompletionHandler:(void (^)(id connection, NSError *error))handler;
- (void)startDiscovering;
- (void)stopDiscovering;
@end

static id<FlameALTServerManager> altServerManager(void) {
    static id<FlameALTServerManager> manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Frameworks/AltKit.framework/AltKit"];
        dlopen([NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Frameworks/CAltKit.framework/CAltKit"].UTF8String, RTLD_GLOBAL);
        dlopen(path.UTF8String, RTLD_GLOBAL);

        Class cls = NSClassFromString(@"ALTServerManager");
        if (!cls) {
            NSLog(@"[FlameJIT] AltKit 이 번들에 없습니다 — AltServer 경로 건너뜀");
            return;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        manager = [cls performSelector:@selector(sharedManager)];
#pragma clang diagnostic pop
    });
    return manager;
}

bool FlameNativeAltServerAvailable(void) { return altServerManager() != nil; }

void FlameNativeRequestAltServerJIT(void (^completion)(bool success, NSString *message)) {
    id<FlameALTServerManager> manager = altServerManager();
    if (!manager) {
        completion(false, @"AltKit 이 앱에 포함되어 있지 않습니다.");
        return;
    }

    [manager startDiscovering];
    [manager autoconnectWithCompletionHandler:^(id connection, NSError *error) {
        if (error || !connection) {
            NSLog(@"[FlameJIT] AltServer 자동 연결 실패: %@", error.localizedRecoverySuggestion);
            completion(false, error.localizedRecoverySuggestion
                ?: @"같은 Wi-Fi 에서 AltServer 를 찾지 못했습니다.");
            return;
        }
        id<FlameALTServerConnection> conn = connection;
        [conn enableUnsignedCodeExecutionWithCompletionHandler:^(BOOL success, NSError *error) {
            [manager stopDiscovering];
            if (success) {
                NSLog(@"[FlameJIT] AltServer 로 JIT 활성화 성공");
                completion(true, nil);
            } else {
                NSLog(@"[FlameJIT] AltServer JIT 실패: %@", error.localizedRecoverySuggestion);
                completion(false, error.localizedRecoverySuggestion ?: @"AltServer 가 JIT 요청을 거절했습니다.");
            }
        }];
    }];
}

void FlameNativeStopAltServerDiscovery(void) {
    [altServerManager() stopDiscovering];
}

// MARK: - 자체 활성화 (TrollStore / 탈옥 전용)

static NSString *const kJITChildMarker = @"--flame-jit-child";

/// 샌드박스가 꺼져 있으면 외부 디버거 없이 스스로 JIT 를 켠다.
///
/// 원리: 자기 자신을 자식으로 띄우고 그 자식이 `ptrace(PT_TRACE_ME)` 를 부르면,
/// 커널이 **추적자인 부모에게도** CS_DEBUGGED 를 준다. 자식은 곧바로 정리한다.
///
/// ⚠️ 일반 사이드로드에는 통하지 않는다 — `com.apple.private.security.no-sandbox` 는
///    TrollStore 나 탈옥으로만 얻을 수 있고, posix_spawn 자체가 샌드박스에서 막힌다.
///    그래서 UIApplicationMain 보다 먼저(생성자에서) 시도하고, 실패해도 조용히 넘어간다.
__attribute__((constructor))
static void flame_preinit(int argc, char **argv) {
    @autoreleasepool {
        // 우리가 띄운 자식이면: 추적 표시만 남기고 즉시 끝낸다.
        if (argc == 2 && argv[1] && strcmp(argv[1], kJITChildMarker.UTF8String) == 0) {
            ptrace(PT_TRACE_ME, 0, 0, 0);
            _exit(0);
        }

        if (FlameNativeIsJITEnabled()) return;
        if (!FlameNativeHasEntitlement(@"com.apple.private.security.no-sandbox")) return;

        NSLog(@"[FlameJIT] no-sandbox 권한 있음 — 자체 JIT 활성화를 시도합니다");
        pid_t pid = 0;
        char *childArgv[] = { argv[0], (char *)kJITChildMarker.UTF8String, NULL };
        if (posix_spawnp(&pid, argv[0], NULL, NULL, childArgv, environ) != 0) {
            NSLog(@"[FlameJIT] posix_spawn 실패 (errno %d)", errno);
            return;
        }

        waitpid(pid, NULL, WUNTRACED);
        ptrace(PT_DETACH, pid, NULL, 0);
        kill(pid, SIGTERM);
        wait(NULL);
        NSLog(@"[FlameJIT] %@", FlameNativeIsJITEnabled() ? @"활성화 성공" : @"활성화 실패");
    }
}

/// 시작 직후 상태를 한 번 찍는다. JIT 는 어떤 경로로 켜지든 눈에 안 보이는 커널 플래그라,
/// 로그가 없으면 "왜 안 되는지" 를 기기에서 확인할 방법이 없다.
__attribute__((constructor))
static void flame_logDiagnostics(void) {
    @autoreleasepool {
        NSLog(@"[FlameJIT] 시작 진단\n%@", FlameNativeDiagnostics());
    }
}

// MARK: - 진단

NSString *FlameNativeDiagnostics(void) {
    return [@[
        [NSString stringWithFormat:@"설치 유형: %@", FlameNativeInstallType()],
        [NSString stringWithFormat:@"JIT 플래그(CS_DEBUGGED): %@",
            FlameNativeIsJITEnabled() ? @"켜짐" : @"꺼짐"],
        [NSString stringWithFormat:@"JIT 메모리(MAP_JIT): %@",
            FlameNativeCanAllocateJITMemory() ? @"확보 가능 ✓" : @"불가 — dynamic-codesigning 권한 없음"],
        [NSString stringWithFormat:@"디버거 연결 허용(get-task-allow): %@",
            FlameNativeIsDebuggable() ? @"예 ✓" : @"아니오 ✗ — 개발용 인증서로 서명해야 합니다"],
        [NSString stringWithFormat:@"TrollStore JIT: %@", FlameNativeHasTrollStoreJIT() ? @"가능" : @"없음"],
        [NSString stringWithFormat:@"AltServer 연동: %@", FlameNativeAltServerAvailable() ? @"가능" : @"없음"],
        [NSString stringWithFormat:@"확장 가상 주소: %@ (없으면 힙 상한이 낮아집니다)",
            FlameNativeHasEntitlement(@"com.apple.developer.kernel.extended-virtual-addressing") ? @"있음" : @"없음"],
        [NSString stringWithFormat:@"메모리 상한 완화: %@",
            FlameNativeHasEntitlement(@"com.apple.developer.kernel.increased-memory-limit") ? @"있음" : @"없음"],
        [NSString stringWithFormat:@"물리 메모리: %llu MB", NSProcessInfo.processInfo.physicalMemory / 1048576],
    ] componentsJoinedByString:@"\n"];
}
