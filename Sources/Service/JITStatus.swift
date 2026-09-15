import Foundation
import Observation
import UIKit

/// JIT 상태와 활성화 흐름. PojavLauncher iOS 의 `invokeAfterJITEnabled:` 에 해당한다.
///
/// 게임을 띄우기 전에 반드시 `enable()` 이 true 를 돌려줘야 한다. JIT 없이 JVM 을 띄우면
/// 코드 캐시를 잡지 못해 부팅 중에 죽거나, 떠도 5 FPS 도 안 나온다.
@Observable
@MainActor
final class JITStatus {
    static let shared = JITStatus()

    /// 어떤 경로로 JIT 를 켤 수 있는지.
    enum Method {
        /// 이미 켜져 있다 (Xcode 실행 중 / 탈옥 / dynamic-codesigning).
        case alreadyOn
        /// TrollStore 가 URL 스킴으로 켜준다.
        case trollStore
        /// 같은 Wi-Fi 의 AltServer 에 붙어 켠다.
        case altServer
        /// StikDebug / SideStore 를 URL 스킴으로 불러 자동으로 켠다.
        /// (Amethyst 의 `invokeAfterJITEnabled:` 와 같은 방식)
        case debugger
        /// 자동 호출이 실패했다 — 사용자가 직접 붙여야 한다.
        case manual
        /// 서명에 get-task-allow 가 없어 어떤 방법으로도 못 켠다.
        case impossible
        /// 디버거는 붙었지만 커널이 실행 권한을 내주지 않는 상태(iOS 26.6 실측).
        case blocked

        var title: String {
            switch self {
            case .alreadyOn:   return "JIT 켜짐"
            case .trollStore:  return "TrollStore 로 JIT 켜기"
            case .altServer:   return "AltServer 로 JIT 켜기"
            case .debugger:    return "JIT 를 켜는 중"
            case .manual:      return "디버거 연결을 기다리는 중"
            case .impossible:  return "이 서명으로는 JIT 를 켤 수 없습니다"
            case .blocked:     return "이 기기에서는 JIT 를 쓸 수 없습니다"
            }
        }

        var detail: String {
            switch self {
            case .alreadyOn:
                return "바로 실행할 수 있어요."
            case .trollStore:
                return "TrollStore 로 전환됐다가 자동으로 돌아옵니다. 별도 조작은 필요 없어요."
            case .altServer:
                return "컴퓨터의 AltServer 와 같은 Wi-Fi 에 있어야 합니다. 찾는 중…"
            case .debugger:
                return """
                StikDebug 로 자동 전환됐다가 곧 돌아옵니다. 별도 조작은 필요 없어요.
                JIT 스크립트도 같이 보내므로 StikDebug 에서 따로 고르지 않아도 됩니다.
                """
            case .manual:
                return """
                기기에서 StikDebug 를 열고 FlameLauncher 를 선택해 JIT 를 켜주세요.
                켜지는 즉시 이 화면이 자동으로 넘어갑니다.

                • iOS 17.4 ~ 26: StikDebug (최초 1회만 컴퓨터로 페어링)
                • iOS 17.0 ~ 17.3: SideJITServer (컴퓨터 + 같은 Wi-Fi)
                """
            case .impossible:
                return """
                앱이 get-task-allow 없이 서명돼 있어서 디버거를 붙일 수 없습니다.
                개발용 인증서(무료 Apple ID 포함)로 다시 서명하거나 TrollStore 로 설치하세요.
                UDID 를 쓰지 않는 서명 서비스(배포 인증서)로는 불가능합니다.
                """
            case .blocked:
                return """
                디버거는 붙어 있습니다(CS_DEBUGGED). 그런데 커널이 실행 권한을 주지 않습니다.

                iPhone 15 / iOS 26.6 에서 직접 재본 결과입니다:
                • mmap(MAP_JIT)         → EPERM (dynamic-codesigning 권한이 있어야 함)
                • mmap(rwx)             → cur=rw- 로 깎임 (max 에만 x 가 남음)
                • 코드를 쓴 뒤 mprotect → cur=r--, max 에서도 x 가 사라짐
                • vm_protect(set_max)   → KERN_PROTECTION_FAILURE

                Xcode 로 디버거를 계속 붙여둬도, StikDebug 으로 켜도 똑같았습니다.
                내가 쓴 코드가 들어있는 페이지는 실행 권한을 받지 못합니다.

                JVM 은 코드 캐시에 스텁을 만들어 실행해야 하므로, 이 상태로는 부팅
                0.2 초 만에 StubRoutines::call_stub 에서 SIGBUS 로 죽습니다.

                남은 방법은 dynamic-codesigning 권한을 주는 설치 경로뿐입니다:
                • TrollStore 로 설치
                • 탈옥 기기
                """
            }
        }
    }

    private(set) var isEnabled = false
    private(set) var isWorking = false
    /// 자동 경로가 실패했을 때 그 사유. 기다리기는 계속한다.
    private(set) var failureMessage: String?

    private(set) var installType = "Unknown"
    private(set) var isDebuggable = false
    private(set) var method: Method = .manual

    var diagnostics: String { FlameNativeDiagnostics() }

    private var waiter: Task<Bool, Never>?

    private init() {
        refresh()
        // 앱이 다시 활성화될 때마다 다시 읽는다. StikDebug 를 다녀온 직후가 여기고,
        // 백그라운드에 오래 있으면 디버거가 떨어져 CS_DEBUGGED 가 풀리기도 한다.
        // 그 상태로 게임을 띄우면 코드 캐시 첫 명령에서 SIGBUS 로 죽는다.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didBecomeActiveNotification) {
                await self?.refresh()
            }
        }
    }

    /// CS_DEBUGGED 는 켜졌는데 커널이 실행 권한을 안 주는 상태.
    /// 이때 진행하면 JVM 이 반드시 SIGBUS 로 죽으므로 실행을 **막는다**.
    private(set) var mayBeBlocked = false

    func refresh() {
        // ⚠️ CS_DEBUGGED 만 보고 "켜짐" 이라고 하면 안 된다. iOS 26.6 에서는 플래그가
        //    서 있어도 커널이 실행 권한을 내주지 않는다(실측) — 그대로 진행하면 JVM 이
        //    코드 캐시 첫 명령에서 SIGBUS 로 죽는다. 실제 권한까지 확인해야 한다.
        let flagOn = FlameNativeIsJITEnabled()
        let canExecute = FlameNativeHasExecutableMemory()
        isEnabled = flagOn && canExecute
        mayBeBlocked = flagOn && !canExecute
        installType = FlameNativeInstallType()
        isDebuggable = FlameNativeIsDebuggable()

        method = {
            if isEnabled { return .alreadyOn }
            // 디버거는 붙었는데 실행 권한이 없다 — 기다려도 달라지지 않는다.
            if mayBeBlocked { return .blocked }

            if FlameNativeHasTrollStoreJIT() { return .trollStore }
            if !isDebuggable { return .impossible }
            if FlameNativeAltServerAvailable() { return .altServer }
            // ⚠️ 예전에는 여기서 바로 .manual 이었다 — 사용자가 StikDebug 를 열고 앱을
            //    고르고 스크립트를 지정하는 걸 매번 손으로 해야 했다.
            //    URL 스킴으로 부르면 그 과정이 통째로 사라진다.
            return .debugger
        }()
    }

    /// JIT 가 켜질 때까지 기다린다. 자동으로 켤 수 있는 경로가 있으면 먼저 시도한다.
    /// - Returns: 켜졌으면 true, 취소했으면 false.
    /// - Parameter deadline: 여기까지도 안 켜지면 포기한다. nil 이면 사용자가 취소할 때까지 기다린다
    ///   (게임 실행 게이트는 화면에 사유를 띄워 두고 기다리는 게 맞다).
    func enable(deadline: ContinuousClock.Instant? = nil) async -> Bool {
        refresh()
        if isEnabled { return true }

        // 기다린다고 풀리는 상태가 아니다 — 권한 자체가 없다.
        if method == .blocked || method == .impossible { return false }

        isWorking = true
        failureMessage = nil
        defer { isWorking = false }

        // ⚠️ iOS 는 **비활성 상태의 openURL 을 조용히 버린다.** 앱이 막 떴을 때가 정확히
        //    그 타이밍이라, 런처를 껐다 켜면 JIT 요청이 나가지도 않고 사라졌다
        //    (그래서 "종종" 안 붙었다 — 뜨는 속도에 따라 갈렸다).
        //    실패해도 에러가 없어서 화면에는 그냥 스피너만 돈다.
        await waitUntilActive()

        switch method {
        case .trollStore:
            _ = FlameNativeRequestTrollStoreJIT()
        case .altServer:
            await requestAltServer()
        case .debugger:
            if !FlameNativeRequestDebuggerJIT() {
                method = .manual
                failureMessage = "JIT 도구를 호출하지 못했습니다. StikDebug 를 직접 열어주세요."
            }
        case .manual, .impossible, .blocked, .alreadyOn:
            break
        }

        // 어떤 경로든 결국 CS_DEBUGGED 가 서기를 기다린다.
        // (TrollStore 는 앱 전환 후, AltServer 는 응답 후, 수동은 사용자가 붙인 뒤)
        let task = Task { await waitUntilEnabled(deadline: deadline) }
        waiter = task
        let result = await task.value
        waiter = nil
        refresh()
        return result
    }

    /// 앱이 foreground-active 가 될 때까지 기다린다(최대 5초).
    /// 여기서 막히면 어차피 URL 도 못 열고 사용자도 화면을 못 본다.
    private func waitUntilActive() async {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while UIApplication.shared.applicationState != .active, ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 런처가 뜰 때 **미리 한 번** 확보해 둔다.
    ///
    /// ⚠️ 예전에는 게임 부팅 시점에만 요청했다. 그런데 설치가 끝나면 곧바로 실행으로
    ///    이어지기 때문에(installAndPlay), 다운로드가 막 끝난 순간 앱이 StikDebug 로
    ///    튀어나갔다 — 설치 흐름 한가운데서 화면이 바뀌어 버린다.
    ///    시작할 때 미리 켜 두면 실행 시점에는 이미 .alreadyOn 이라 아무 일도 안 일어난다.
    ///
    /// 자동으로 켤 수 없는 상태(수동·차단·불가)면 **아무것도 하지 않는다** —
    /// 런처를 열자마자 설명 없는 팝업이 뜨는 게 더 나쁘다. 그건 실행할 때 게이트가 맡는다.
    func prepareAtLaunch() async {
        refresh()
        guard !isEnabled, method == .debugger || method == .trollStore else { return }
        // 30초 안에 안 붙으면 접는다. 실행할 때 게이트가 화면과 함께 다시 시도한다.
        _ = await enable(deadline: .now.advanced(by: .seconds(30)))
    }

    /// 사용자가 "다시 확인"을 눌렀을 때 — 자동 경로를 한 번 더 시도한다.
    func retry() async {
        refresh()
        guard !isEnabled else { return }
        if method == .altServer {
            isWorking = true
            await requestAltServer()
            isWorking = false
        } else if method == .trollStore {
            _ = FlameNativeRequestTrollStoreJIT()
        } else if method == .debugger {
            _ = FlameNativeRequestDebuggerJIT()
        }
        refresh()
    }

    func cancel() {
        waiter?.cancel()
        waiter = nil
        FlameNativeStopAltServerDiscovery()
    }

    private func requestAltServer() async {
        let message: String? = await withCheckedContinuation { continuation in
            FlameNativeRequestAltServerJIT { success, message in
                continuation.resume(returning: success ? nil : (message ?? "AltServer 연결 실패"))
            }
        }
        failureMessage = message
    }

    /// 200ms 마다 확인한다 — PojavLauncher iOS 와 같은 주기.
    /// 폴링인 이유: 어느 경로로 켜지든 커널 플래그가 서는 시점을 알려주는 알림이 없다.
    private func waitUntilEnabled(deadline: ContinuousClock.Instant?) async -> Bool {
        while !(FlameNativeIsJITEnabled() && FlameNativeHasExecutableMemory()) {
            if Task.isCancelled { return false }
            // 시작 시 확보처럼 화면에 아무것도 안 띄운 경로는 무한히 돌면 안 된다.
            if let deadline, ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }
}
