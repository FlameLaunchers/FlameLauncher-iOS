//
//  flame_jit26.m
//  iOS 26 디버거 보조 JIT (JIT26).
//
//  AngelAuraMC/Amethyst-iOS 의 Natives/utils.m 에서 이식했다 (GPL-3.0).
//
//  ── 왜 필요한가 ──────────────────────────────────────────────────────────
//  iOS 26 + TXM 기기에서는 프로세스가 자기 힘으로 실행 가능 메모리를 못 얻는다.
//  CS_DEBUGGED 가 서 있어도 마찬가지다 — 직접 재봤다:
//    • mmap(MAP_JIT)         → EPERM
//    • mmap(rwx, MAP_PRIVATE)→ cur=rw- 로 깎임
//    • 코드를 쓴 뒤 mprotect  → cur=r--, max 에서도 x 가 사라짐
//
//  그래서 **디버거가 대신 할당해 준다**. 앱이 `brk` 로 트랩을 걸면 StikDebug 의
//  JIT 스크립트(UniversalJIT26.js)가 gdb-remote `_M<size>,rx` 패킷으로 RX 영역을
//  잡아서 x0 에 돌려준다. 프로세스에는 없는 권한이 디버거에는 있다.
//
//  ── 누가 부르는가 ────────────────────────────────────────────────────────
//  번들 JRE 의 libjvm.dylib 이 **이미 이 규약으로 패치돼 있다**. 바이너리에
//  `brk #0x69` 와 "[JIT26] Got JIT mapping %p from debugger" 문자열이 들어 있다.
//  JVM 은 TXM 여부를 `dlsym(RTLD_DEFAULT, "DeviceHasTXM")` 로 묻고, 없으면
//  환경변수 XNU_HAS_TXM 을 본다. 그래서 호스트인 우리가 그 심볼을 내보내야 한다.
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#include <dirent.h>
#include <dlfcn.h>
#include <limits.h>
#include <sys/mman.h>
#include <unistd.h>

#import "FlameNative.h"

// MARK: - 디버거 트랩 (jitcall)
//
// x16 에 명령 번호를 넣고 `brk #0xf00d` 로 디버거를 부른다. 스크립트가 pc 를 4 만큼
// 밀어주므로 트랩 다음 명령으로 정상 복귀한다. 레거시 `brk #0x69` 는 JVM 이 쓰는
// 경로라 반드시 살아 있어야 한다 — Extension 스크립트가 핸들러를 붙여준다.
//
// ⚠️ naked 함수다. 컴파일러가 프롤로그를 넣으면 스크립트가 읽는 레지스터가 틀어진다.

#if !TARGET_OS_SIMULATOR

__attribute__((noinline, optnone, naked))
void *JIT26CreateRegionLegacy(size_t len) {
    asm("brk #0x69 \n"
        "ret");
}

__attribute__((noinline, optnone, naked))
void *JIT26PrepareRegion(void *addr, size_t len) {
    asm("mov x16, #1 \n"
        "brk #0xf00d \n"
        "ret");
}

__attribute__((noinline, optnone, naked))
static void BreakSendJITScript(char *script, size_t len) {
    asm("mov x16, #2 \n"
        "brk #0xf00d \n"
        "ret");
}

__attribute__((noinline, optnone, naked))
void JIT26SetDetachAfterFirstBr(BOOL value) {
    asm("mov x16, #3 \n"
        "brk #0xf00d \n"
        "ret");
}

__attribute__((noinline, optnone, naked))
void JIT26PrepareRegionForPatching(void *addr, size_t size) {
    asm("mov x16, #4 \n"
        "brk #0xf00d \n"
        "ret");
}

#else

// 시뮬레이터에는 코드서명 강제도 TXM 도 없다. 트랩을 걸면 디버거가 없어 그대로 죽는다.
void *JIT26CreateRegionLegacy(size_t len) { return NULL; }
void *JIT26PrepareRegion(void *addr, size_t len) { return addr; }
static void BreakSendJITScript(char *script, size_t len) {}
void JIT26SetDetachAfterFirstBr(BOOL value) {}
void JIT26PrepareRegionForPatching(void *addr, size_t size) {}

#endif

void JIT26SendJITScript(NSString *script) {
    NSCAssert(script, @"스크립트가 nil 이면 안 된다");
    BreakSendJITScript((char *)script.UTF8String, script.length);
}

/// 디버거가 **지금도** 붙어 있는지.
/// CS_DEBUGGED 는 한 번 서면 남지만, JIT 스크립트는 디버거가 살아 있어야 응답한다.
/// getppid() 는 디버거가 붙어 있을 때만 launchd(1) 가 아닌 값을 준다.
BOOL JIT26IsLikelyDebuggerKeepAttached(void) {
    return getppid() != 1;
}

// MARK: - 기기 판정

/// RW 로 잡아 쓴 페이지를 RX 로 넘길 수 있는가.
///
/// ⚠️ `MAP_SHARED` 다. MAP_PRIVATE 로 재면 iOS 가 무조건 x 를 떼서 항상 실패한다
///    (내가 처음에 그렇게 재서 "JIT 불가능" 이라고 잘못 결론냈다).
///    익명 MAP_SHARED 는 Mach 메모리 객체가 뒤에 붙어서 W^X 취급이 다르다.
///    mprotect 를 두 번 부르는 것도 Amethyst 그대로다 — 첫 번째가 조용히 깎이는
///    경우가 있어 두 번 다 성공해야 진짜 된다고 본다.
BOOL DeviceCanCreateRXMap(void) {
    uint32_t *map = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE,
                         MAP_ANONYMOUS | MAP_SHARED, -1, 0);
    if (map == MAP_FAILED) return NO;
    *map = 0xFFFFFFFF;
    int ret = mprotect(map, getpagesize(), PROT_READ | PROT_EXEC)
            | mprotect(map, getpagesize(), PROT_READ | PROT_EXEC);
    munmap(map, getpagesize());
    return ret == 0;
}

static BOOL flame_atLeastOS(NSInteger major) {
    NSOperatingSystemVersion v = { .majorVersion = major, .minorVersion = 0, .patchVersion = 0 };
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:v];
}

/// TXM(Trusted Execution Monitor) 이 있는 기기인가.
/// 26.6 / 27.0 에서는 /private/preboot 를 못 읽어서 칩 ID 로 추정한다 — Amethyst 와 동일.
static BOOL DeviceHasTXMReal(void) {
    DIR *d = opendir("/private/preboot");
    if (!d) {
        NSUInteger (*MGGetSInt64Answer)(NSString *) = dlsym(RTLD_DEFAULT, "MGGetSInt64Answer");
        if (!MGGetSInt64Answer) return flame_atLeastOS(19);
        switch (MGGetSInt64Answer(@"ChipID")) {
            case 0x8020:  // A12
            case 0x8027:  // A12X/Z
                return NO;
            case 0x8030:  // A13
            case 0x8101:  // A14
            case 0x8103:  // M1
                return flame_atLeastOS(27);
            default:
                return flame_atLeastOS(19);
        }
    }

    struct dirent *dir;
    char txmPath[PATH_MAX] = {0};
    while ((dir = readdir(d)) != NULL) {
        if (strlen(dir->d_name) == 96) {
            snprintf(txmPath, sizeof(txmPath),
                     "/private/preboot/%s/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4",
                     dir->d_name);
            break;
        }
    }
    closedir(d);
    return txmPath[0] != '\0' && access(txmPath, F_OK) == 0;
}

FlameJITFlags FlameNativeGetJITFlags(BOOL refresh) {
    static FlameJITFlags cachedFlags = 0;
    static dispatch_once_t onceToken;
    if (refresh) onceToken = 0;
    dispatch_once(&onceToken, ^{
        // 디버깅용 강제 지정. Amethyst 와 같은 이름이라 값도 그대로 쓸 수 있다.
        const char *s = getenv("JIT_FLAGS");
        if (s) {
            cachedFlags = (s[0] == '0' && tolower(s[1]) == 'b')
                ? (FlameJITFlags)strtoul(s + 2, NULL, 2)
                : (FlameJITFlags)strtoul(s, NULL, 0);
            NSLog(@"[JIT26] JIT 플래그 강제 지정: 0x%X", cachedFlags);
            return;
        }

        if (flame_atLeastOS(26)) {
            cachedFlags |= FlameJITFlagIsIOS26;
            if (!DeviceCanCreateRXMap()) cachedFlags |= FlameJITFlagForceMirrored;
        }

        if (DeviceHasTXMReal()) cachedFlags |= FlameJITFlagHasTXM;

        // ⚠️ 맥('Designed for iPad')에서 ForceMirrored 를 **강제하지 말 것.**
        //
        //    솔깃한 이유가 있다: 맥은 MAP_JIT 을 안 내주고(EINVAL 22, 애드혹으로
        //    allow-jit 을 붙여도 그대로), 그래서 HotSpot 의 기본 코드 캐시 경로가
        //    막혀 JVM 이 사실상 인터프리터로 돈다 — 데이터픽서가 아이폰 293ms 대비
        //    맥에서 60,742ms 였다. 반면 RW→mprotect RX 는 열려 있어서(cur=r-x),
        //    미러 매핑이 딱 맞는 우회로처럼 보인다.
        //
        //    실제로 해보면 죽는다: EXC_BREAKPOINT (code=1).
        //    미러 매핑을 켜면 libjvm 이 **디버거에게** 코드 캐시를 달라고 brk 를 건다.
        //    기기에서는 StikDebug 이 UniversalJIT26.js 로 그 트랩에 답하지만, 맥에는
        //    답해 줄 스크립트가 없다(Xcode 디버거는 그 규약을 모른다).
        //
        //    즉 맥에서는 어느 쪽으로도 JIT 이 안 된다. 인터프리터로 도는 것을
        //    받아들이거나, 맥에서는 이 앱 대신 데스크톱 런처를 쓰는 수밖에 없다.
        NSLog(@"[JIT26] 계산된 JIT 플래그: 0x%X (iOS26=%d mirrored=%d TXM=%d)",
              cachedFlags,
              (cachedFlags & FlameJITFlagIsIOS26) != 0,
              (cachedFlags & FlameJITFlagForceMirrored) != 0,
              (cachedFlags & FlameJITFlagHasTXM) != 0);
    });
    return cachedFlags;
}

BOOL FlameNativeHasJITFlags(FlameJITFlags flags) {
    return (FlameNativeGetJITFlags(NO) & flags) == flags;
}

/// ⭐️ libjvm.dylib 이 `dlsym(RTLD_DEFAULT, "DeviceHasTXM")` 로 찾는 심볼.
/// 이게 없으면 JVM 은 XNU_HAS_TXM 환경변수로 폴백하고, 그것도 없으면 잘못된 경로로
/// 가서 코드 캐시를 실행하다 SIGBUS 로 죽는다. 이름을 바꾸면 안 된다.
///
/// ⚠️ 조건이 `requiresTXMWorkaround`(= -XX:+MirrorMappedCodeCache 를 주는 조건)와
///    **반드시 같아야 한다.** 예전에는 TXM 비트만 봤는데, 그러면 "TXM 이라고 답했지만
///    미러 매핑은 안 해주는" 상태가 만들어진다. libjvm 은 코드 캐시의 RW/RX 두 뷰가
///    있다고 믿고 동작하다가 엉뚱한 주소를 읽는다:
///
///      SIGSEGV at PcDescCache::add_pc_desc+0x68
///
///    맥('Designed for iPad')에서 실제로 그렇게 죽었다 — 거기서는 RX 를 직접 만들 수
///    있어서(mirrored=0) 미러가 필요 없는데 TXM 비트만 켜져 있었다.
__attribute__((visibility("default")))
BOOL DeviceHasTXM(void) {
    return FlameNativeHasJITFlags(FlameJITFlagForceMirrored | FlameJITFlagHasTXM);
}

/// StikDebug 에서 "Assign Script" 로 고를 수 있게 번들의 스크립트를 Documents 에 꺼내둔다.
/// (파일 앱에서 FlameLauncher 폴더를 열면 보인다 — Info.plist 의 UIFileSharingEnabled)
__attribute__((constructor))
static void flame_exportJITScript(void) {
    @autoreleasepool {
        NSString *src = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
        if (!src) return;

        NSString *dst = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/UniversalJIT26.js"];
        NSFileManager *fm = NSFileManager.defaultManager;
        // 앱을 업데이트하면 스크립트도 바뀔 수 있다 — 내용이 다르면 덮어쓴다.
        if ([fm contentsEqualAtPath:src andPath:dst]) return;

        [fm removeItemAtPath:dst error:nil];
        NSError *err = nil;
        if ([fm copyItemAtPath:src toPath:dst error:&err]) {
            NSLog(@"[JIT26] JIT 스크립트를 Documents 에 꺼내뒀습니다: %@", dst);
        } else {
            NSLog(@"[JIT26] JIT 스크립트 복사 실패: %@", err.localizedDescription);
        }
    }
}
