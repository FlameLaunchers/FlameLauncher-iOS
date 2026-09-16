import Foundation
import QuartzCore
import UIKit

/// 게임(JVM)과 런처 UI 사이의 유일한 경계.
///
/// 실제 구현은 `Sources/Natives/` 의 Objective-C 브릿지 —
/// PojavLauncher iOS 의 JavaLauncher / input_bridge_v3 / egl_bridge 를 옮긴 것 — 이고,
/// 이 프로토콜은 그 위에 얇게 씌운 Swift 표면이다.
///
/// 스텁이 따로 있는 이유: JRE 나 렌더러 dylib 이 아직 없을 때도 화면 버튼·조이스틱·패드·
/// 키보드 매핑을 눌러보며 검증할 수 있어야 하기 때문이다.
protocol JavaRuntime: AnyObject {
    /// 게임을 실제로 실행할 수 있는 상태인지.
    var isAvailable: Bool { get }
    /// 아니라면 그 이유 — 사용자에게 그대로 보여준다.
    var unavailableReason: String { get }

    func setEnv(_ env: [String: String])
    func attach(layer: CALayer, size: CGSize)

    /// JVM 을 띄우고 mainClass 를 실행한다. 게임이 끝날 때까지 돌아오지 않는다.
    func boot(javaHome: URL, argv: [String]) async throws -> Int32

    // ── 입력 중계 ──
    func sendKey(_ glfwKey: Int, action: Int, mods: Int)
    func sendChar(_ scalar: UInt32)
    func sendMouseButton(_ button: Int, action: Int)
    /// 인게임(grab)이면 델타로, 메뉴면 절대좌표로 해석된다.
    func sendCursorPos(_ x: Double, _ y: Double, relative: Bool)
    func sendScroll(_ dx: Double, _ dy: Double)
    func setScreenSize(_ width: Int, _ height: Int)

    /// 게임이 마우스를 잡고 있는지(=인게임). false 면 메뉴/인벤토리.
    var isGrabbing: Bool { get }
    /// 네이티브가 실제 스왑 수로 계산한 FPS. 아직 한 프레임도 안 나왔으면 -1.
    var fps: Int { get }
    /// jetsam 까지 남은 여유(MB). 모르면 -1.
    var availableMemoryMb: Int { get }
    /// 자바 스레드 덤프를 로그에 남긴다 — 부팅이 멈췄을 때 어디서 막혔는지 보려고.
    func dumpThreads()
    /// 첫 프레임이 그려졌는지 — 부팅 오버레이를 내릴 시점.
    var hasRendered: Bool { get }

    /// 앱이 백그라운드로 갈 때 게임을 일시정지시킨다.
    func pause()
    func stop()
}

/// 실행 조건이 갖춰졌으면 실제 런타임, 아니면 스텁.
enum GameRuntime {
    static let current: JavaRuntime = {
        NativeJavaRuntime.isReady ? NativeJavaRuntime() as JavaRuntime : StubJavaRuntime()
    }()
}

// MARK: - 실제 런타임

/// `Sources/Natives/` 의 브릿지를 그대로 호출하는 구현.
///
/// ⚠️ 안드로이드판은 libflamejvm.so 를 따로 만들어 JNI 로 불렀지만, iOS 는 브릿지가
///    **앱 바이너리 안**에 있다. 패치된 LWJGL 이 `pojav*` / `Java_org_lwjgl_glfw_*` 심볼을
///    프로세스 전역 심볼 테이블에서 찾기 때문에 이렇게 해야 연결된다.
final class NativeJavaRuntime: JavaRuntime {

    /// 게임을 띄우는 데 필요한 **파일**이 다 있는지.
    ///
    /// ⚠️ JIT 는 여기서 보지 않는다. `GameRuntime.current` 는 한 번만 평가되는데, 앱 시작
    ///    시점에는 대개 JIT 가 꺼져 있다 — 그때 스텁으로 굳어버리면 게이트가 JIT 를 켠 뒤에도
    ///    영영 스텁을 쓰게 된다. JIT 는 실행 직전에 `JITStatus` 가 따로 확인한다.
    static var isReady: Bool { missingPieces.isEmpty }

    /// 빠진 것들의 목록 — 그대로 사용자에게 보여준다.
    static var missingPieces: [String] {
        var missing: [String] = []
        #if targetEnvironment(simulator)
        // ⚠️ 번들 JRE·렌더러는 전부 기기용 arm64(iOS 플랫폼) 바이너리다. 시뮬레이터에서
        //    dlopen 하면 코드서명 검증에 걸려 프로세스가 SIGKILL 로 죽는다 — 잡을 수 있는
        //    예외가 아니라서, 시도 자체를 막는다.
        missing.append("""
        • 시뮬레이터에서는 게임을 실행할 수 없습니다
          JRE·렌더러가 전부 기기용(arm64, iOS) 바이너리라 시뮬레이터가 열지 못합니다.
          UI 확인은 시뮬레이터에서, 실제 실행은 기기에서 하세요.
        """)
        #endif
        if JavaInstallStore.installed().isEmpty {
            missing.append("""
            • JRE 가 없습니다
              앱에 함께 넣으려면: Scripts/fetch-runtime.sh 를 돌리고 다시 빌드하세요.
              기기에 직접 넣으려면: 파일 앱 → FlameLauncher → runtimes/java-17-openjdk/
            """)
        }
        if !FileManager.default.fileExists(atPath: frameworksDir.appending(path: "liblwjgl.dylib").path) {
            missing.append("""
            • 렌더러/LWJGL 네이티브가 없습니다
              Scripts/fetch-runtime.sh 를 돌리고 다시 빌드하세요.
            """)
        }
        return missing
    }

    static var frameworksDir: URL {
        Bundle.main.bundleURL.appending(path: "Frameworks")
    }

    var isAvailable: Bool { true }
    var unavailableReason: String { "" }

    var isGrabbing: Bool { FlameNativeIsGrabbing() }
    var fps: Int { Int(FlameNativeCurrentFPS()) }
    var availableMemoryMb: Int { Int(FlameNativeAvailableMemoryMB()) }

    func dumpThreads() { FlameNativeDumpThreads() }
    var hasRendered: Bool { FlameNativeHasRendered() }

    func setEnv(_ env: [String: String]) {
        for (key, value) in env { FlameNativeSetEnv(key, value) }
    }

    func attach(layer: CALayer, size: CGSize) {
        FlameNativeSetSurfaceLayer(layer)
        FlameNativeSetScreenSize(Int32(size.width), Int32(size.height))
    }

    /// 네이티브가 돌려준 실패 코드를 사람이 읽을 수 있는 사유로.
    static func launchFailureReason(_ code: Int32) -> String? {
        switch code {
        case Int32(FLAME_LAUNCH_ERR_SIMULATOR):
            return "시뮬레이터에서는 게임을 실행할 수 없습니다 — 기기용 바이너리라 열 수 없어요."
        case Int32(FLAME_LAUNCH_ERR_NO_JLI):
            return "JRE 에 libjli.dylib 이 없습니다. runtimes 폴더의 JRE 가 온전한지 확인해 주세요."
        case Int32(FLAME_LAUNCH_ERR_DLOPEN):
            return "JRE 를 열지 못했습니다. 기기용(arm64) iOS 빌드가 맞는지 확인해 주세요."
        case Int32(FLAME_LAUNCH_ERR_NO_SYMBOL):
            return "JRE 에서 JLI_Launch 를 찾지 못했습니다. 손상된 JRE 로 보입니다."
        case Int32(FLAME_LAUNCH_ERR_NO_DEBUGGER):
            return """
            디버거가 붙어 있지 않습니다.

            이 기기(iOS 26 + TXM)는 JVM 이 코드 캐시를 직접 못 잡아서, 디버거가 대신
            실행 가능 메모리를 잡아줘야 합니다. StikDebug 으로 JIT 를 켠 **그 상태 그대로**
            게임을 실행해 주세요. 앱을 다시 띄우면 연결이 끊깁니다.
            """
        case Int32(FLAME_LAUNCH_ERR_JIT_SCRIPT):
            return """
            StikDebug 에 JIT 스크립트가 지정되지 않았습니다.

            StikDebug 에서 JIT 를 켤 때 FlameLauncher 를 **길게 눌러** \"Assign Script\" 를
            고르고, 내장 스크립트 중 **universal** 을 선택해 주세요.

            목록에 universal 이 없는 구버전이라면 StikDebug 를 업데이트하거나,
            파일 앱 → FlameLauncher → UniversalJIT26.js 를 직접 고르셔도 됩니다.
            (앱이 실행될 때 그 파일을 Documents 에 자동으로 꺼내둡니다)
            """
        default:
            return nil   // 0 이상 = JVM 이 그 코드로 정상 종료
        }
    }

    func boot(javaHome: URL, argv: [String]) async throws -> Int32 {
        // JLI_Launch 는 게임이 끝날 때까지 돌아오지 않는다 — 전용 스레드에서 돌린다.
        // (메인 스레드는 UIKit 것이라 내줄 수 없다. HACK_IGNORE_START_ON_FIRST_THREAD=1 로
        //  -XstartOnFirstThread 요구를 무시하게 해 뒀다.)
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let thread = Thread {
                let code = Self.withCStrings(argv) { pointer, count in
                    FlameNativeLaunchJVM(javaHome.path, pointer, Int32(count))
                }
                continuation.resume(returning: code)
            }
            // JVM 은 스택을 많이 쓴다 — 기본 512KB 로는 클래스 로딩 중에 넘친다.
            thread.stackSize = 8 * 1024 * 1024
            thread.name = "FlameJVM"
            thread.start()
        }
    }

    func sendKey(_ glfwKey: Int, action: Int, mods: Int) {
        FlameNativeSendKey(Int32(glfwKey), Int32(GlfwKeys.sdlScancode(for: glfwKey)),
                           Int32(action), Int32(mods))
    }

    func sendChar(_ scalar: UInt32) { FlameNativeSendChar(scalar) }

    func sendMouseButton(_ button: Int, action: Int) {
        FlameNativeSendMouseButton(Int32(button), Int32(action), 0)
    }

    func sendCursorPos(_ x: Double, _ y: Double, relative: Bool) {
        FlameNativeSendCursorPos(relative ? 1 : 0, x, y)
    }

    func sendScroll(_ dx: Double, _ dy: Double) { FlameNativeSendScroll(dx, dy) }

    func setScreenSize(_ width: Int, _ height: Int) {
        FlameNativeSetScreenSize(Int32(width), Int32(height))
    }

    func pause() { FlameNativePauseGame() }

    /// JVM 은 프로세스 안에서 되돌릴 수 없다 — 게임을 끝내면 앱도 함께 끝난다.
    /// (PojavLauncher iOS 도 같은 제약이라 exit 훅으로 앱을 정리한다)
    func stop() { FlameNativePauseGame() }

    /// [String] → C 의 `const char *[]`. 배열 수명이 클로저 안에서만 유효하다.
    private static func withCStrings<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafePointer<CChar>>, Int) -> R
    ) -> R {
        let cStrings = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>] = cStrings.map { UnsafePointer($0!) }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!, buffer.count)
        }
    }
}

// MARK: - 스텁

/// 런타임이 준비되지 않았을 때 쓰는 구현.
///
/// 입력은 전부 받아서 기록만 한다 — 그래서 JRE 없이도 화면 버튼·조이스틱·패드·키보드
/// 매핑을 실제로 눌러보며 검증할 수 있다. 부팅만 거부한다.
final class StubJavaRuntime: JavaRuntime {
    private(set) var lastEvent = "입력 대기 중"
    private(set) var eventCount = 0

    var isAvailable: Bool { false }

    var unavailableReason: String {
        """
        게임을 실행할 준비가 아직 안 됐습니다.

        \(NativeJavaRuntime.missingPieces.joined(separator: "\n"))

        \(FlameNativeDiagnostics())

        준비 방법은 README 의 '네이티브 런타임' 절을 참고하세요.
        """
    }

    var isGrabbing: Bool { false }
    var fps: Int { -1 }
    var availableMemoryMb: Int { -1 }

    func dumpThreads() { record("dumpThreads") }
    var hasRendered: Bool { false }

    func setEnv(_ env: [String: String]) { record("env \(env.count)개") }
    func attach(layer: CALayer, size: CGSize) {
        record("layer \(Int(size.width))×\(Int(size.height))")
    }

    func boot(javaHome: URL, argv: [String]) async throws -> Int32 {
        throw LoaderInstallError.unsupported(unavailableReason)
    }

    func sendKey(_ glfwKey: Int, action: Int, mods: Int) {
        record("key \(glfwKey) \(action == GlfwKeys.press ? "↓" : "↑")")
    }
    func sendChar(_ scalar: UInt32) {
        record("char \(String(UnicodeScalar(scalar) ?? " "))")
    }
    func sendMouseButton(_ button: Int, action: Int) {
        record("mouse \(button) \(action == GlfwKeys.press ? "↓" : "↑")")
    }
    func sendCursorPos(_ x: Double, _ y: Double, relative: Bool) {
        record(String(format: "cursor %@%.0f,%.0f", relative ? "Δ" : "", x, y))
    }
    func sendScroll(_ dx: Double, _ dy: Double) { record("scroll \(dy)") }
    func setScreenSize(_ width: Int, _ height: Int) { record("size \(width)×\(height)") }
    func pause() {}
    func stop() {}

    private func record(_ text: String) {
        lastEvent = text
        eventCount += 1
    }
}
