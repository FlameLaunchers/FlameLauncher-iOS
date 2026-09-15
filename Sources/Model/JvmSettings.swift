import Foundation
import UIKit

/// 안드로이드 `data.jvm.JvmSettings` 이식. 기본값·인자 구성 모두 그대로 유지한다.
struct JvmSettings: Codable, Equatable {
    /// ⚠️ 이 값은 **자바 힙**에만 쓰인다. 마인크래프트의 텍스처 아틀라스는 `NativeImage` —
    ///    힙 밖이다. jetsam 한도 안에서 둘이 자리를 나눠 쓰므로 힙을 키울수록 아틀라스가
    ///    쓸 자리가 줄어든다. 실측(아이폰 15, jetsam 한도 3071 MB,
    ///    CobbleVerse + 모드 250개 + 리소스팩 15개):
    ///      -Xmx2048 → 아틀라스를 시작하기도 전에 3027 MB, 여유 6 MB 에서 jetsam
    ///      -Xmx1280 → 자바 힙 OutOfMemoryError (jetsam 여유는 770 MB 남아돌았다)
    ///    힙 밖이 1 GB 남짓을 쓰므로 고를 수 있는 창이 좁다. 그 사이를 기본값으로 잡는다.
    var maxHeapMb: Int = 1536
    var minHeapMb: Int = 512
    var useG1GC: Bool = true
    var gcPauseMillis: Int = 100
    var parallelRefProc: Bool = true
    var heapRegionSizeMb: Int = 32
    var disableClouds: Bool = true
    var extraJvmArgs: String = ""      // 줄바꿈 구분 커스텀 인자
    var mouseSensitivity: Double = 1.5
    var renderDistance: Int = 4
    var graphicsMode: Int = 0          // 0=fast, 1=fancy, 2=fabulous
    var unlockFps: Bool = true
    var fullscreen: Bool = true
    var resolutionScalePercent: Int = 100

    /// HUD(인벤토리·핫바) 크기. 0 = 마인크래프트 기본, 그 외는 강제할 GUI 스케일.
    ///
    /// ⚠️ 마인크래프트는 "가상 화면 ≥ 320x240" 을 하드코딩해서 GUI 스케일에 상한을 건다
    ///    (`Window.calculateScale`). 폰 가로 화면에서는 높이가 먼저 걸려 스케일 2 에서
    ///    막히고, 슬롯 한 칸이 22pt — 애플 권장 터치 영역 44pt 의 절반이다.
    ///    해상도를 어떻게 만져도 최대 1.28배까지밖에 못 키운다.
    ///    그래서 0 이 아니면 에이전트가 그 하한 자체를 낮춘다([[IosFsAgent.patchGuiFloor]]).
    var hudScale: Int = 0

    static let resScaleMin = 25
    static let resScaleMax = 100

    var resolutionScale: Double {
        Double(min(max(resolutionScalePercent, Self.resScaleMin), Self.resScaleMax)) / 100
    }

    /// 화면 픽셀에 배율을 적용한 실제 렌더 해상도.
    /// GL 백엔드 안정성을 위해 짝수로 맞추고 최소 2px 을 보장한다.
    func scaledResolution(_ width: Int, _ height: Int) -> (Int, Int) {
        let s = resolutionScale
        let w = max(Int(Double(width) * s) & ~1, 2)
        let h = max(Int(Double(height) * s) & ~1, 2)
        return (w, h)
    }

    /// 바닐라에서 **가장 키가 큰** 화면의 높이(GUI 단위) — 대형 상자(6줄, 114+6*18).
    /// 가상 화면이 이보다 낮으면 그 화면의 위아래가 화면 밖으로 잘린다.
    ///
    /// ⚠️ 마인크래프트의 하한 240 이 바로 이것에 여유를 둔 값이다. 우리가 하한을 낮출 때도
    ///    이 선은 지켜야 "HUD 는 커졌는데 상자를 못 쓴다" 가 안 된다.
    ///    (인벤토리·제작대·모루는 166 이라 더 여유롭다)
    static let tallestGuiHeight = 222

    /// 이 프레임버퍼에서 **아무것도 잘리지 않는** 최대 GUI 스케일.
    static func maxHudScale(framebufferHeight: Int) -> Int {
        max(1, min(framebufferHeight / tallestGuiHeight, 4))
    }

    /// 사용자가 고른 HUD 크기를 잘리지 않는 범위로 자른다.
    static func effectiveHudScale(_ hudScale: Int, framebufferHeight: Int) -> Int {
        min(hudScale, maxHudScale(framebufferHeight: framebufferHeight))
    }

    /// 마인크really가 실제로 쓸 GUI 스케일. 핫바 터치 영역도 이 값으로 잡는다.
    static func effectiveGuiScale(
        hudScale: Int, optionsGuiScale: Int, framebuffer: (w: Int, h: Int)
    ) -> Int {
        let auto = max(1, min(framebuffer.w / 320, framebuffer.h / 240))
        guard hudScale > 0 else {
            // "자동" 이면 게임 안에서 고른 값을 존중하고, 범위를 벗어나면 마인크래프트와
            // 같은 규칙으로 되돌린다.
            return (1...auto).contains(optionsGuiScale) ? optionsGuiScale : auto
        }
        return effectiveHudScale(hudScale, framebufferHeight: framebuffer.h)
    }

    /// `hudScale` 을 실제로 받아내기 위해 낮춰야 하는 하한 `"<w>x<h>"`.
    /// 이미 기본 하한으로도 되는 값이면 nil(패치할 이유가 없다).
    static func guiFloorSpec(hudScale: Int, framebuffer: (w: Int, h: Int)) -> String? {
        let scale = effectiveHudScale(hudScale, framebufferHeight: framebuffer.h)
        guard scale > 1 else { return nil }
        let floorW = min(320, framebuffer.w / scale)
        let floorH = min(240, framebuffer.h / scale)
        guard floorW < 320 || floorH < 240 else { return nil }
        return "\(floorW)x\(floorH)"
    }

    /// 이 HUD 스케일을 **잘림 없이** 쓰려면 필요한 최소 렌더 해상도(%).
    /// 설정 화면이 "60% 이상이면 3배 가능" 을 안내하는 데 쓴다.
    static func minResolutionPercent(forHudScale scale: Int, fullHeightPx: Int) -> Int? {
        guard scale > 1, fullHeightPx > 0 else { return nil }
        let needed = tallestGuiHeight * scale
        let percent = Int((Double(needed) / Double(fullHeightPx) * 100).rounded(.up))
        // 슬라이더가 5 단위라 거기에 맞춰 올린다.
        let snapped = (percent + 4) / 5 * 5
        return snapped <= resScaleMax ? max(snapped, resScaleMin) : nil
    }

    /// 이 해상도 배율에서 마인크래프트가 **실제로 허용하는** GUI 스케일.
    ///
    /// ⚠️ 설정에서 GUI 스케일을 3·4 로 올려도 마인크래프트가 되돌린다.
    ///    `Window.calculateScale` 이 "가상 화면 ≥ 320x240" 을 강제하기 때문이다:
    ///
    ///        for (i = 1; i != guiScale && fbW/(i+1) >= 320 && fbH/(i+1) >= 240; ++i);
    ///
    ///    세로로 긴 폰 화면에서는 항상 높이가 먼저 걸려서 `fbH/240` 이 천장이 된다.
    ///    즉 **해상도 배율이 HUD 크기를 결정한다** — 그런데 비례가 아니라 톱니라서,
    ///    배율을 올렸는데 HUD 가 오히려 작아지는 구간이 생긴다(실측 iPhone 15):
    ///
    ///        45% → 1150x503, 스케일 2, 가상 575x251   (HUD 1.22배, 픽셀 0.67배)
    ///        55% → 1405x614, 스케일 2, 가상 702x307   (기준)
    ///        65% → 1661x726, 스케일 3, 가상 553x242   (HUD 1.27배, 픽셀 1.40배)
    ///       100% → 2556x1118, 스케일 4, 가상 639x279  (HUD 1.10배, 픽셀 3.31배)
    ///
    ///    가상 높이가 240 에 가까울수록 HUD 가 크다(최대 ~1.28배). 슬라이더에
    ///    이걸 같이 보여주지 않으면 사용자는 이 톱니를 알 방법이 없다.
    static func guiScale(fullHeightPx: Int, percent: Int) -> Int {
        let h = Int(Double(fullHeightPx) * Double(percent) / 100)
        return max(1, min(h / 240, 4))
    }

    /// HUD 한 칸이 화면에서 차지하는 비율. 값이 클수록 HUD 가 크다.
    /// (= GUI 스케일 / 프레임버퍼 높이. 가상 높이의 역수와 같다)
    static func hudRelativeSize(fullHeightPx: Int, percent: Int) -> Double {
        let h = Double(fullHeightPx) * Double(percent) / 100
        return Double(guiScale(fullHeightPx: fullHeightPx, percent: percent)) / h
    }

    /// 마지막으로 게임이 보고한 **100% 기준** 프레임버퍼 높이(px).
    /// 게임을 한 번도 안 띄웠으면 화면 크기로 어림한다(안전영역만큼 오차가 난다).
    static var lastFullFramebufferHeight: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: "flame.fullFbHeight")
            guard saved <= 0 else { return saved }
            let b = UIScreen.main.nativeBounds   // 항상 세로 기준이라 가로 높이는 width
            return Int(min(b.width, b.height))
        }
        set { UserDefaults.standard.set(newValue, forKey: "flame.fullFbHeight") }
    }

    // ⚠️ 여기에 `-XX:AllocateHeapAt` 으로 **자바 힙을 파일에 올리는** 길이 있었다. 지웠다.
    //
    //    되기는 됐다 — 코블버스 footprint 가 3053 → 480 MB 로 떨어졌다. 그런데 대가가
    //    감당이 안 됐다. 부팅 419초 중 **GC 가 254초(61%)**, 1초 넘는 멈춤 28회, 최대 37.6초.
    //    GC 는 힙 전체를 무작위로 훑는데 그 페이지가 디스크에 있으면 매번 폴트다.
    //    (네이티브 데이터는 반대다 — 한 번 쓰고 순차로 읽으니 파일에 어울린다.
    //     그쪽은 flame_alloc.c 가 계속 맡는다)
    //
    //    그리고 애초에 필요가 없었다. 같은 실행에서 라이브 셋은 1199 MB, 힙 밖은 885 MB
    //    였다 — 힙을 RAM 에 두고도 예산 안에 들어간다. 옛 추정치(라이브 셋 1885)를
    //    믿고 과하게 잡았던 것이다. 지금은 천장이 RAM 에 확실히 들어가는 값이라
    //    이 길로 갈 일 자체가 없다(maxHeapCeilingMb 주석).
    //
    //    ⚠️ 되살리려면 `-XX:+AlwaysPreTouch` 로 폴트를 부팅 때 몰아 치우고 싶어지는데,
    //       **그건 안 된다.** AlwaysPreTouch 는 코드 캐시도 미리 만지고, 우리 코드 캐시는
    //       미러 매핑이라 RX 쪽이 쓰기 불가다. 그 자리에서 SIGBUS 로 죽는다:
    //         [JIT26] mapping at RW=0x1394a8000, RX=0x12f4a8000
    //         SIGBUS at os::pretouch_memory+0x3c, si_addr: 0x12f4a8000

    /// 큰 네이티브 할당을 **파일 기반 매핑**으로 돌리는 할당자를 LWJGL 에 물린다.
    ///
    /// ⚠️ iOS 의 jetsam 은 `phys_footprint` 로 판정하는데, 거기에는 익명 메모리와 압축분만
    ///    들어가고 **파일 기반(external)은 안 들어간다**. 실측(바닐라 1.21.4 + 서버
    ///    리소스팩, 죽기 직전):
    ///
    ///        footprint 2759 MB = 익명 1135 + 압축 1528 · 파일기반 27
    ///          tag 0 (JVM 힙·JIT)                1294 MB
    ///          malloc_small (스프라이트 수천 장)   781 MB
    ///          malloc_large (아틀라스 256 포함)    697 MB
    ///
    ///    마인크래프트의 `NativeImage` 와 GL 스테이징 버퍼는 전부 LWJGL 의 `MemoryUtil` 을
    ///    지나가므로, 할당자 하나만 갈아끼우면 그만큼이 장부에서 빠진다. 힙(JVM)은 못
    ///    옮기지만 나머지는 옮길 수 있다. (구현: Sources/Natives/flame_alloc.c)
    ///
    /// ⚠️ 주소를 인자로 넘기는 이유: dylib 은 JVM 보다 **먼저** 이 프로세스에 올라와 있어
    ///    주소가 이미 확정이다. JVM 이 뜬 뒤 `System.setProperty` 로 심으면 LWJGL 의
    ///    `MemoryUtil` 이 그보다 먼저 초기화될 수 있어 늦는다.
    static func allocatorArgs() -> [String] {
        var pointers = [UInt64](repeating: 0, count: 6)
        flame_alloc_pointers(&pointers)
        guard pointers.allSatisfy({ $0 != 0 }) else { return [] }

        let names = ["malloc", "calloc", "realloc", "free", "aligned_alloc", "aligned_free"]
        return zip(names, pointers).map { "-Dflame.alloc.\($0)=\($1)" }
             + ["-Dorg.lwjgl.system.allocator=kr.co.donghyun.flame.FlameAllocator"]
    }

    /// JVM 인자 배열. 안드로이드 `toJvmArgArray` 에 PojavLauncher iOS 의 iOS 전용 인자를 더했다.
    ///
    /// ⚠️ `org.lwjgl.opengl.libname` 은 **여기서도** 내보낸다.
    ///    네이티브 브릿지가 `System.setProperty` 로 다시 심기는 하지만, LWJGL 의
    ///    `org.lwjgl.opengl.GL` 이 먼저 초기화되면 그 시점의 값을 읽고 굳어버린다.
    ///    (그래서 "Core OpenGL functions could not be found" 로 죽었다)
    ///    setProperty 는 나중에 덮어쓰는 것이므로 둘이 충돌하지 않는다 — 상류도 둘 다 한다.
    ///
    /// ⚠️ 클래스패스도 여기 넣지 않는다 — JLI_Launch 에 `-cp` 로 따로 넘긴다.
    func jvmArgs(
        instanceDir: URL,
        userDir: String,
        libraryPath: String,
        mainClass: String,
        versionId: String,
        renderer: Renderer,
        screenSize: (Int, Int)
    ) -> [String] {
        let cache = Paths.caches.path
        // ⚠️ libraryPath 는 ':' 로 이어진 **목록**일 수 있다(26.2 는 Frameworks341 을 앞에 둔다).
        //    절대경로가 필요한 곳에는 공용 dylib 이 있는 마지막 항목(기본 Frameworks)을 쓴다.
        let baseFrameworks = libraryPath.split(separator: ":").last.map(String.init) ?? libraryPath
        var args: [String] = [
            // ⚠️ 반드시 넣어야 한다. Darwin JLI 는 이 옵션이 있어야 `JavaMain` 을
            //    **자기가 만든 apple_main 스레드에서 그대로** 실행한다(sameThread 경로).
            //    빼면 JavaMain 이 또 다른 새 pthread(ThreadJavaMain)에서 돌고, 그 스레드는
            //    JIT 실행 권한을 못 받아 첫 생성 코드(`StubRoutines::call_stub`)에서
            //    SIGBUS/BUS_ADRALN 으로 죽는다 — Apple 의 W^X 상태는 **스레드별**이다.
            //
            //    이 옵션 때문에 JLI 가 앱 진입점을 다시 부르는데, 그건 정상 설계이며
            //    `FlameNativeContinueJVM()` 이 받아 처리한다(FlameLauncherMain 참고).
            "-XstartOnFirstThread",
            "-Xmx\(maxHeapMb)M",
            "-Xms\(minHeapMb)M",
            "-XX:+UnlockExperimentalVMOptions",
            // 스택 가드 페이지를 무작위로 할당하다 나는 크래시 회피 (PojavLauncher iOS)
            "-XX:+DisablePrimordialThreadGuardPages",
            // JNA 는 iOS 를 모른다 — Platform 이 스스로를 macOS 로 보고 libjnidispatch 를
            // 클래스패스에서 꺼내려다 UnsatisfiedLinkError 를 낸다(oshi 가 CPU 정보를
            // 읽을 때 터진다). 이 에이전트가 com.sun.jna.Platform 을 갈아끼운다.
            "-javaagent:\(Bundle.main.bundleURL.appending(path: "libs/patchjna_agent.jar").path)=",
            // JDK 21 의 toRealPath 는 대소문자 무시 파일시스템(APFS)에서 경로를 루트부터
            // 훑는다 — iOS 샌드박스가 /private·/var 를 막아서 **항상** 실패한다.
            // 이 에이전트가 MacOSXFileSystem.isCaseInsensitiveAndPreserving 을 false 로
            // 바꿔 그 훑기를 끈다. (Cobblemon 의 Showdown 샌드박스가 이것 때문에 죽었다)
            "-javaagent:\(Bundle.main.bundleURL.appending(path: "libs/flame_bootstrap.jar").path)",
            "-Djna.nosys=true",
            "-Doshi.os=ios",
            "-Dio.netty.native.workdir=\(cache)",
            "-Djna.tmpdir=\(cache)",
            // LWJGL 이 "GLFW 는 첫 스레드에서만" 검사를 하는데, 위 이유로 통과할 수 없다.
            "-Dorg.lwjgl.glfw.checkThread0=false",
            // ⚠️ 여기서 할당자를 지정하지 않는다. 뒤에 오는 allocatorArgs() 가
            //    파일 기반 매핑 할당자를 지정하는데, 같은 -D 가 두 번 나가면 헷갈린다.
            "-Dlog4j2.formatMsgNoLookups=true",
        ]

        // ⭐️ iOS 26 이상에서 JIT 를 살리는 유일한 스위치.
        //
        //    이 기기는 프로세스가 실행 가능 메모리를 못 얻는다(MAP_JIT=EPERM, rwx 요청은
        //    cur=rw- 로 깎이고, 코드를 쓴 페이지는 mprotect 로도 x 가 붙지 않는다).
        //    그래서 패치된 libjvm 은 코드 캐시를 **RW 와 RX 로 두 번 매핑(mirror)** 하고,
        //    RX 쪽은 디버거(StikDebug)에게 `brk #0x69` 로 받아온다.
        //
        //    그 경로 전체가 이 플래그 하나로 잠겨 있다. 안 주면 libjvm 이
        //    get_debug_jit_mapping() 초입에서 그냥 빠져나가([JIT26] 로그가 한 줄도
        //    안 나온다) 평범한 코드 캐시를 잡고, 스텁을 실행하는 순간
        //    StubRoutines::call_stub 에서 SIGBUS 로 죽는다.
        //    ⚠️ 조건은 **OS 버전이 아니라 실제 능력**이어야 한다. 예전에는 "OS 26 이상"
        //       이었는데, 같은 26 이어도 실행 가능 메모리를 그냥 얻을 수 있는 환경
        //       (맥에서 'Designed for iPad' 로 돌릴 때가 그렇다)에서는 미러 경로가
        //       필요 없다. 그런데도 플래그를 주면 libjvm 이 있지도 않은 디버거에게
        //       코드 캐시를 달라고 brk 를 걸고 그대로 선다.
        //       네이티브의 requiresTXMWorkaround 와 **같은 식**이라 기기 동작은 그대로다.
        if FlameNativeHasJITFlags([.forceMirrored, .hasTXM]) {
            args.append("-XX:+MirrorMappedCodeCache")
        }

        // ⚠️ 맥에서 'Designed for iPad' 로 돌릴 때는 **JIT 을 아예 끈다.**
        //    macOS 는 MAP_JIT 에 `com.apple.security.cs.allow-jit` 을 요구하는데, 그건
        //    macOS 하드닝 런타임 키라 iOS 프로비저닝 프로파일이 허가하지 않는다 —
        //    엔타이틀먼트에 넣어도 **서명 단계에서 떨어져 나간다**(확인함).
        //    그러면 mmap MAP_JIT 이 EINVAL(22) 로 거부되고, JIT 으로 만든 코드 페이지에
        //    실행 권한이 안 붙어서 그 코드를 실행하는 순간 죽는다:
        //      SIGSEGV, SEGV_ACCERR, si_addr == pc
        //        J 2405 c1 org.objectweb.asm.ClassReader.createDebugLabel

        if useG1GC {
            args += [
                "-XX:+UseG1GC",
                "-XX:MaxGCPauseMillis=\(gcPauseMillis)",
                parallelRefProc ? "-XX:+ParallelRefProcEnabled" : "-XX:-ParallelRefProcEnabled",
                // ⚠️ 안드로이드 쪽 튜닝은 둘 다 20 이었다. 힙이 4 GB 일 때는 괜찮지만
                //    iOS 는 jetsam 예산 때문에 1.5 GB 언저리로 묶이는데, 20 + 20 이면
                //    **힙의 40% 가 살아있는 객체를 담는 데 못 쓰인다**(young 예약 + 대피 예비).
                //    CobbleVerse 처럼 상주 데이터가 큰 팩에서는 그만큼이 그대로 모자라서,
                //    G1 이 satisfy_failed_allocation → Full GC 를 무한 반복하고 게임이 선다
                //    (스택 덤프로 확인했다 — 전체 스레드가 세이프포인트에 묶여 있었다).
                //    상주 데이터가 큰 대신 할당률은 낮은 워크로드라 young 은 작아도 된다.
                "-XX:G1NewSizePercent=5",
                "-XX:G1ReservePercent=10",
                "-XX:G1HeapRegionSize=\(heapRegionSizeMb)m",
                // ⚠️ 놀고 있는 힙을 OS 에 돌려준다. G1 의 기본값(Min 40 / Max 70)은
                //    램을 독차지하는 서버 기준이라 한 번 커밋한 힙을 거의 내놓지 않는다.
                //    실측(1.21.4 + 서버 리소스팩): 커밋 1088MB 인데 GC 후 실사용은 537MB,
                //    551MB 가 놀고 있었다. 그 상태에서 8192² 아틀라스를 잡으려다
                //    남은 여유 577MB 를 넘겨 jetsam 으로 죽었다.
                //    아틀라스·렌더러는 전부 힙 **밖**이라, 힙이 쥐고만 있는 건 순손실이다.
                //    후속 실측(같은 서버, 위 설정 적용 후): 커밋 928MB · GC 후 실사용
                //    665MB → 노는 몫이 28.3% 로 **Max 30 바로 아래**라 G1 이 끝내 반납하지
                //    않았다. 263MB 가 그대로 묶인 채 footprint 2930~3069MB 에서 죽었다.
                //    한도를 더 조인다: 665 / 0.85 ≈ 782MB → 약 150MB 를 돌려받는다.
                "-XX:MinHeapFreeRatio=5",
                "-XX:MaxHeapFreeRatio=15",
                // ⚠️ 비율만 낮춰서는 부족하다. G1 은 **GC 를 할 때만** 반납한다.
                //    할당률이 낮은 구간(로딩 끝난 뒤)에서는 GC 가 안 돌아서 커밋이
                //    그대로 남는다. 주기적 동시 GC 를 켜서 반납 기회를 만든다.
                //    (SystemLoadThreshold 기본 0 = 부하와 무관하게 돈다)
                "-XX:G1PeriodicGCInterval=15000",
                "-XX:+G1PeriodicGCInvokesConcurrent",
            ]
        }

        // FPS cap 해제 자체는 options.txt 가 하지만, 이 옵션들은 GC pause 가 프레임
        // 사이에 끼어드는 걸 줄여서 unlocked FPS 가 실제로 매끄럽게 나오게 해준다.
        if unlockFps {
            args += [
                "-XX:+DisableExplicitGC",
                // ⚠️ AlwaysPreTouch 는 빼야 한다. Aikar 플래그는 램을 독차지하는 서버용이라,
                //    시작하자마자 힙 전체를 한 페이지씩 만지며 커밋한다. iOS 에서는 그게
                //    os::pretouch_memory 에서 SIGBUS 로 죽는다(실측) — 미러 매핑된 코드
                //    캐시와 제한된 주소 공간 위에서는 통째로 선점할 수 없다.
                //    Amethyst 도 이 플래그를 쓰지 않는다.
                "-XX:+ParallelRefProcEnabled",
                "-XX:G1MixedGCCountTarget=4",
                "-XX:InitiatingHeapOccupancyPercent=15",
                "-XX:G1RSetUpdatingPauseTimePercent=5",
                "-XX:SurvivorRatio=32",
                "-XX:+PerfDisableSharedMem",
                "-XX:MaxTenuringThreshold=1",
            ]
        }

        args += [
            // GC 일시정지를 한 줄씩 남긴다. 프레임이 끊길 때 GC 때문인지 아닌지를
            // 추측이 아니라 시간으로 확인할 수 있어야 한다(한 줄짜리라 로그가 안 늘어난다).
            // ── 힙 **밖** 상한 ────────────────────────────────────────────────
            //
            // -Xmx 는 자바 힙만 묶는다. 그런데 jetsam 예산은 프로세스 전체를 본다 —
            // 실측(CobbleVerse, 모드 137개): 힙 1920M 을 빼고도 **1122M** 이 힙 밖에
            // 있었고, 여유가 29MB 까지 몰렸다. 그 1122M 의 큰 조각이 메타스페이스와
            // JIT 코드 캐시인데 둘 다 기본값이 사실상 무제한이다.
            //
            // 모드가 많을수록 클래스가 많아 메타스페이스가, 코드가 많아 코드 캐시가
            // 같이 자란다. 상한을 두면 그만큼이 힙과 텍스처 몫으로 남는다.
            //
            // ⚠️ 너무 조이면 안 된다. 메타스페이스가 모자라면
            //    OutOfMemoryError: Metaspace 로 죽고, 코드 캐시가 차면 JIT 가 꺼져
            //    인터프리터로 떨어진다(살아는 있지만 매우 느리다).
            //    384M / 160M 은 모드 140개대에서 여유가 있는 값이다.
            "-XX:MaxMetaspaceSize=384M",
            "-XX:ReservedCodeCacheSize=160M",
        ] + Self.allocatorArgs() + [
            "-Xlog:gc:stdout:time,level,tags",
            "-Duser.dir=\(userDir)",
            "-Duser.home=\(instanceDir.deletingLastPathComponent().path)",
            "-Djava.library.path=\(libraryPath)",
            "-Dorg.lwjgl.librarypath=\(libraryPath)",
            "-Dping.main.class=\(mainClass)",
            // ⚠️ **쓸 수 있는 곳**이어야 한다. 예전에는 앱 번들의 Frameworks/ 를 가리켰는데,
            //    거긴 읽기 전용이다. 마인크래프트 26.2 가 새로 들어온 NativeLibrariesBootstrap
            //    에서 이 경로 아래에 LWJGL 버전 폴더를 만들려다 부팅 직후 죽는다:
            //      FileSystemException: …/FlameLauncher.app/Frameworks/3.3.3-snapshot:
            //        Operation not permitted
            //    (그 전 버전들은 만들지 않고 읽기만 해서 드러나지 않았다)
            //
            //    우리 dylib 을 **찾는** 건 위의 org.lwjgl.librarypath 가 하므로,
            //    추출 경로는 캐시로 빼도 된다(패치된 lwjgl.jar 에는 추출할 네이티브가 없다).
            "-Dorg.lwjgl.system.SharedLibraryExtractPath=\(cache)/lwjgl",
            "-Dorg.lwjgl.system.SharedLibraryExtractDirectory=\(cache)/lwjgl",
            // ⚠️ NoChecks 를 켜면 LWJGL 이 함수 포인터가 0 인지 확인하지 않는다.
            //    그러면 매핑 안 된 함수를 부르는 순간 예외 대신 JVM 이 통째로 죽는다
            //    ("FATAL ERROR in native method … The JVM will abort execution").
            //    26.2 의 glGenSamplers 가 정확히 그랬다 — 원인을 읽을 수가 없었다.
            //    검사 비용은 포인터 비교 하나다. 켜 둔다.

            "-Dfml.earlyprogresswindow=false",
            "-Dorg.lwjgl.opengl.Display.allowSoftwareOpenGL=true",
            "-Djava.io.tmpdir=\(cache)",
            "-Duser.timezone=\(TimeZone.current.identifier)",
        ]

        // LWJGL 3.4.1 스택에서는 LWJGL 자신의 진단을 켠다.
        //
        // GLCapabilities 는 진입점 주소를 **버전 묶음 단위**로 채운다. 묶음 안에서 하나라도
        // 못 찾으면 그 묶음 전체가 0 으로 남을 수 있어서, 정작 있는 함수까지 못 쓰게 된다.
        // Debug=true 면 못 찾은 함수 이름을 하나씩 찍어 준다:
        //     [LWJGL] Failed to locate address for GL function <이름>
        //     [LWJGL] [GL] OpenGL33 was reported as available but an entry point is missing.
        // 26.2 가 부팅을 마치면 이 줄은 뺀다. 1.21.x(3.3.3)에는 켜지 않는다 — 로그만 늘어난다.
        if baseFrameworks != libraryPath {
            args.append("-Dorg.lwjgl.util.Debug=true")
        }

        // 확장 가상 주소 권한이 없으면(무료 개발자 계정 등) 압축 클래스 공간 할당이 실패한다.
        if !Self.hasExtendedVirtualAddressing {
            args.append("-XX:-UseCompressedClassPointers")
        }

        // ── Cacio (AWT 가상 백엔드) ──────────────────────────────────
        // 일부 모드(FancyMenu/JourneyMap 등)가 java.awt.* 를 호출하는데 번들 JRE 에는
        // headful AWT 네이티브가 없어서 Toolkit 로드 중 UnsatisfiedLinkError 로 죽는다.
        // cacio 가 toolkit 을 가로채면 그 네이티브 자체가 불필요해진다.
        //
        // ⚠️ JRE 버전별로 주입 방식이 완전히 다르다 — 섞으면 JVM 이 아예 뜨지 않는다.
        //    JRE9+ 에 `-Xbootclasspath/p:` 를 주면 그 옵션이 제거됐기 때문에 거부당한다.
        //
        // jar 이름을 하드코딩하지 않고 번들 폴더를 훑는다 — fetch-runtime.sh 가 가져오는
        // cacio 버전이 올라가도 여기를 고칠 일이 없다.
        let isJava8 = VersionRules.javaMajor(versionId) <= 8
        let cacioDir = Bundle.main.bundleURL
            .appending(path: isJava8 ? "libs_caciocavallo" : "libs_caciocavallo17")
        let cacioJars = ((try? FileManager.default.contentsOfDirectory(
            at: cacioDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jar" }
            .map(\.path)
            .sorted()
            .joined(separator: ":")

        args += [
            "-Djava.awt.headless=false",
            "-Dcacio.managed.screensize=\(screenSize.0)x\(screenSize.1)",
            // ⭐️ 패치된 org.lwjgl.glfw.GLFW 의 static 초기화가 이걸 읽는다:
            //      String[] size = System.getProperty("glfw.windowSize").split("x");
            //    Amethyst 는 자체 래퍼 메인(PojavLauncher)에서 cacio.managed.screensize 를
            //    복사해 넣지만, 우리는 마인크래프트 Main 을 직접 부르므로 여기서 넘긴다.
            //    없으면 GLFW.<clinit> 이 NPE 로 죽고 렌더 스레드가 통째로 멈춘다.
            "-Dglfw.windowSize=\(screenSize.0)x\(screenSize.1)",
            // LWJGL 이 GL 함수 포인터를 어느 dylib 에서 가져올지. GL.createCapabilities()
            // 가 이걸 읽으므로 JVM 시작 시점에 이미 정해져 있어야 한다.
            "-Dorg.lwjgl.opengl.libname=\(renderer.libName)",
            // MoltenVK 는 파일 이름이 표준과 달라 LWJGL 이 못 찾는다(래퍼가 하던 일).
            "-Dorg.lwjgl.vulkan.libname=libMoltenVK.dylib",
            // SPIRV-Cross — 마인크래프트 26.2 부터 부팅할 때 무조건 로드한다.
            //
            // ⚠️ **절대경로로 준다.** 26.2 의 NativeLibrariesBootstrap 이
            //    `configureLWJGLLibraryPath()` 에서 추출 경로를
            //    `<extract>/<LWJGL 버전>/<아키텍처>` 로 바꿔치기하고 거기서 찾게 만든다.
            //    그 폴더는 비어 있고(우리 lwjgl.jar 은 네이티브를 뺀 판이라 추출할 게 없다)
            //    우리 Frameworks/ 는 더 이상 보지 않는다.
            //    LWJGL 의 loadNative 는 이름이 절대경로면 **가장 먼저** 그걸 그대로 연다.
            "-Dorg.lwjgl.spvc.libname=\(baseFrameworks)/libspirv-cross.dylib",
            // iOS 에는 macOS 용 Preferences 백엔드가 없다 — 파일 기반으로 돌린다.
            "-Djava.util.prefs.PreferencesFactory=java.util.prefs.FileSystemPreferencesFactory",
            "-Dcacio.font.fontmanager=sun.awt.X11FontManager",
            "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler",
        ]

        if isJava8 {
            args += [
                "-Xbootclasspath/p:\(cacioJars)",
                "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel",
                "-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit",
                "-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment",
            ]
        } else {
            args += [
                "-Xbootclasspath/a:\(cacioJars)",
                "-Dswing.defaultlaf=javax.swing.plaf.nimbus.NimbusLookAndFeel",
                "-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit",
                "-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment",
            ]
            args += Self.cacioModuleFlags
        }

        args += extraJvmArgs
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return args
    }

    /// java.desktop / java.base 내부 패키지 개방 (JRE9+ 모듈 캡슐화 우회).
    private static let cacioModuleFlags = [
        "--add-exports=java.desktop/java.awt=ALL-UNNAMED",
        "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED",
        "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.font=ALL-UNNAMED",
        "--add-exports=java.base/sun.security.action=ALL-UNNAMED",
        "--add-opens=java.base/java.util=ALL-UNNAMED",
        "--add-opens=java.desktop/java.awt=ALL-UNNAMED",
        "--add-opens=java.desktop/sun.font=ALL-UNNAMED",
        "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED",
        "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
        "--add-opens=java.base/java.net=ALL-UNNAMED",
    ]
}

enum JvmSettingsStore {
    private static let file = JSONFile(name: "jvm_settings.json", fallback: JvmSettings())

    static func load() -> JvmSettings {
        var s = file.load()
        s.resolutionScalePercent = min(max(s.resolutionScalePercent, JvmSettings.resScaleMin),
                                       JvmSettings.resScaleMax)
        // ⚠️ 예전 천장(물리 메모리의 절반)으로 저장해 둔 값은 jetsam 예산을 통째로 먹어서
        //    아틀라스가 쓸 자리를 남기지 않는다. 더는 고를 수 없는 값이면 권장값으로 되돌린다.
        // ⚠️ 천장을 넘으면 **천장으로 깎는다** — 기본값으로 되돌리지 않는다.
        //    되돌리면 2176 로 저장해 둔 설정이 1536 으로 떨어지는데, 실측상 그건
        //    코블버스의 라이브 셋(1199MB)을 93% 점유로 담아서 GC 가 폭주한다
        //    (80초 동안 483회). 쓸 수 있는 만큼은 그대로 쓰게 둔다.
        if s.maxHeapMb > maxHeapCeilingMb { s.maxHeapMb = maxHeapCeilingMb }
        return s
    }

    static func save(_ s: JvmSettings) { file.save(s) }
    static func reset() -> JvmSettings { let d = JvmSettings(); save(d); return d }

    /// 기기 물리 메모리(MB). 안내 문구에만 쓴다.
    static var totalRamMb: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }

    /// 이 앱이 jetsam 으로 죽기 전까지 쓸 수 있는 전체 예산(MB).
    ///
    /// ⚠️ 물리 메모리의 절반 같은 어림이 아니라 **OS 가 알려주는 실제 한도**다.
    ///    (아이폰 15 = 물리 6GB 인데 앱 한도는 3071 MB 였다)
    static var jetsamBudgetMb: Int {
        let available = Int(FlameNativeAvailableMemoryMB())
        let used = Int(FlameNativeMemoryFootprintMB())
        guard available > 0, used > 0 else { return max(1024, totalRamMb / 2) }
        return available + used
    }

    /// 힙 슬라이더의 천장.
    ///
    /// ⚠️ 예전에는 물리 메모리의 절반(6GB 기기에서 3072MB)이었다. 그건 jetsam 예산과
    ///    거의 같은 값이라, 슬라이더를 끝까지 올리면 **아틀라스가 쓸 자리가 0** 이 되어
    ///    반드시 죽는 설정을 고를 수 있었다. 예산에서 힙 밖 몫을 떼고 남는 만큼만 연다.
    ///    (예산의 절반으로 자르는 것도 해봤지만 이번엔 반대로 빡빡해서 — 1280 은 힙 OOM 이
    ///     났다 — 정답 구간을 막았다)
    /// ⚠️ **RAM 에 확실히 들어가는 값**이어야 한다.
    ///    예전 천장(예산 − 힙밖)은 2175 였는데, 그건 여유가 10 MB 밖에 안 남는 값이라
    ///    슬라이더를 끝까지 올리면 반드시 죽거나(RAM) 디스크로 밀려나(느림) 버렸다.
    ///    슬라이더의 최대값이 곧 함정인 셈이었다.
    ///
    /// ⚠️ 여유분은 128 이다. 처음엔 256 을 뗐는데 그러면 천장이 1919 가 되고, 코블버스가
    ///    리소스 리로드 피크에서 힙을 89% 까지 채워 GC 가 돌기만 하다 멈춘다.
    ///    그 피크는 **지나가는 값**이다 — 같은 팩이 부팅을 마치면 라이브 셋이 1199,
    ///    타이틀에서는 832 MB 까지 내려간다. 그 한 번을 넘길 머리 공간이 필요하다.
    ///    힙 밖은 실측 890 MB 에서 더 자라지 않는다(네이티브는 파일로 빠져 있다).
    static var maxHeapCeilingMb: Int { max(1024, jetsamBudgetMb - offHeapFloorMb - 128) }

    /// 힙 밖(아틀라스·렌더러·JVM 자체)이 최소한 쓰는 양.
    ///
    /// ⚠️ 예전 값은 1024 였다. 그건 **파일 기반 매핑 할당자가 생기기 전** 측정이다
    ///    (힙을 1280 으로 묶어도 프로세스 전체가 2298 MB). 지금은 마인크래프트의
    ///    NativeImage·GL 버퍼가 전부 파일 기반으로 빠져서 footprint 에 안 잡힌다 —
    ///    실측(바닐라 1.21.4 + 서버 리소스팩): 전체 1150 = 힙커밋 736 + **힙 밖 414**.
    ///
    ///    무거운 모드팩에서는 메타스페이스·코드 캐시·JIT 미러가 커진다. 힙을 파일에
    ///    올린 채로 코블버스(모드 137개)를 끝까지 돌려 **힙 밖만** 따로 쟀다:
    ///    최대 885 MB. 그 실측값에 여유를 붙인다.
    static let offHeapFloorMb = 896
}

extension JvmSettings {
    /// `com.apple.developer.kernel.extended-virtual-addressing` 권한 유무.
    /// 없으면 JVM 이 압축 클래스 공간을 잡지 못해 부팅 중에 죽는다.
    static let hasExtendedVirtualAddressing: Bool = {
        FlameNativeDiagnostics().contains("확장 가상 주소 권한: 있음")
    }()
}
