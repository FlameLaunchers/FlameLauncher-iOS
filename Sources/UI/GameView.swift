import SwiftUI

/// 게임 화면 전체. 안드로이드 `MinecraftActivity` + `MinecraftSurface` 조합 이식.
///
/// 구성(아래에서 위로):
///   1. GameSurface  — 게임이 그려지는 CAMetalLayer + 터치/키보드 입력
///   2. GameControlsView — 화면 버튼 + 조이스틱 + FPS
///   3. BootOverlayView  — 첫 프레임이 나올 때까지 덮는 로딩 화면
///   4. InGameMenuView   — ☰ 로 여는 오른쪽 슬라이드 패널
struct GameView: View {
    let meta: InstanceMeta

    @Environment(LauncherModel.self) private var launcher
    @Environment(AuthStore.self) private var auth
    @Environment(\.scenePhase) private var scenePhase

    @State private var jit = JITStatus.shared

    @State private var runtime = GameRuntime.current
    @State private var settings = JvmSettingsStore.load()
    @State private var appSettings = AppSettingsStore.load()

    @State private var controlsVisible = AppSettingsStore.load().controllerVisible
    @State private var guiScale = 0
    @State private var combatMode = false

    @State private var isBooting = true
    @State private var showJITGate = false
    @State private var bootError: String?
    @State private var fps = -1
    @State private var freeMemoryMb = -1
    @State private var isGrabbing = false
    @State private var showMenu = false
    @State private var showKeyboard = false

    @State private var gamepad: GamepadHandler?
    @State private var surface: MinecraftSurfaceView?
    @State private var pollTimer: Timer?

    /// 레이어 종류를 결정하므로 서피스를 만들기 전에 정해져야 한다.
    private var renderer: Renderer { RendererStore.resolve(for: meta) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GameSurface(
                runtime: runtime, settings: settings, renderer: renderer,
                guiScale: $guiScale,
                onReady: boot,
                onCreate: { surface = $0 }
            )
            // ⚠️ 아래쪽 SafeArea 도 내주지 않는다 — 화면을 꽉 채운다.
            //
            //    예전에는 홈 인디케이터 띠(약 21pt)를 비워 뒀다. 화면 맨 아래에서
            //    **시작하는 드래그**는 시스템이 먼저 가져가서(iOS 에 홈 제스처를 완전히
            //    끄는 API 는 없다 — `defersSystemGestures` 도 "한 번 더 쓸어야 나감"
            //    이지 무효화가 아니다) 인벤토리 맨 아랫줄을 못 끄는 문제가 있었다.
            //
            //    이제 HUD 크기를 직접 키울 수 있으니 그 띠를 비워 둘 이유가 없다.
            //    비워 두면 프레임버퍼 높이가 줄어 오히려 HUD 상한이 내려간다
            //    (GUI 스케일 천장 = 프레임버퍼높이/240 이다).
            .ignoresSafeArea()

            if !isBooting {
                GameControlsView(
                    runtime: runtime,
                    visible: $controlsVisible,
                    // grab 중이 아니면(메뉴/인벤토리/타이틀) ESC 만 남긴다.
                    escOnlyMode: !isGrabbing,
                    fps: fps,
                    freeMemoryMb: freeMemoryMb,
                    onMenu: { showMenu = true },
                    onSoftKeyboard: { showKeyboard = true },
                    onCombatToggle: {
                        combatMode.toggle()
                        surface?.combatMode = combatMode
                    },
                    combatMode: combatMode
                )
                .ignoresSafeArea()
            }

            // JIT 게이트가 부팅 오버레이보다 위다 — JIT 없이는 부팅 자체를 시작하지 않는다.
            if showJITGate {
                JITGateView(onCancel: dismiss).environment(jit)
            } else if isBooting {
                BootOverlayView(
                    modCount: InstanceStore.shared.modCount(meta),
                    error: bootError,
                    onClose: dismiss
                )
            }

            // 채팅용 소프트 키보드. 안드로이드는 InputConnection 을 직접 구현했지만,
            // iOS 는 숨긴 TextField 하나로 같은 일을 한다(입력된 글자를 char 콜백으로 흘린다).
            if showKeyboard {
                ChatInputField(
                    onChar: { runtime.sendChar($0) },
                    onBackspace: {
                        runtime.sendKey(GlfwKeys.backspace, action: GlfwKeys.press, mods: 0)
                        runtime.sendKey(GlfwKeys.backspace, action: GlfwKeys.release, mods: 0)
                    },
                    onSubmit: {
                        runtime.sendKey(GlfwKeys.enter, action: GlfwKeys.press, mods: 0)
                        runtime.sendKey(GlfwKeys.enter, action: GlfwKeys.release, mods: 0)
                        showKeyboard = false
                    },
                    onDismiss: { showKeyboard = false })
            }
        }
        .statusBarHidden(settings.fullscreen)
        .lockOrientation(.landscape)
        .persistentSystemOverlays(.hidden)
        // ⚠️ **비워서 명시**해야 한다. 모디파이어를 빼면 SwiftUI 기본값이 남는데,
        //    실측해 보니 `UIHostingController` 는 기본으로 좌·우 가장자리를 지연한다:
        //      [FlameHome] …(autoHide=true edges=0xa …) → PresentationHostingController(edges=0xa)
        //                                        0xa = left|right
        //    가장자리를 하나라도 지연하면 iOS 는 "여기는 한 번 더 쓸어야 나갑니다" 를
        //    알리려고 홈 인디케이터를 계속 띄워 두고, 그러면 바로 위의
        //    `.persistentSystemOverlays(.hidden)` 이 무력화된다.
        //
        //    지연을 버려도 원래 목적은 남는다 — 인디케이터가 숨겨져 있으면 iOS 는 먼저
        //    한 번 쓸어야 인디케이터를 띄우므로 바닥에서 시작하는 드래그는 어차피 보호된다.
        //
        //    ⚠️ `prefersHomeIndicatorAutoHidden` 은 "요청" 일 뿐이고 표시/숨김 시점은
        //       iOS 가 정한다 — 만지면 띄우고 가만히 두면 몇 초 뒤 내린다. 그 지연 시간을
        //       바꾸는 공개 API 는 없다(완전히 없애려면 사용자가 '안내 접근'을 켜야 한다).
        //       실측으로 확인한 최종 상태: `autoHide=true edges=0x0`.
        //
        // ⚠️ 바닥 지연은 **화면이 열려 있을 때만** 건다.
        //
        //    지연과 자동 숨김은 서로 배타적이다 — 가장자리를 하나라도 지연하면 iOS 가
        //    "한 번 더 쓸어야 나갑니다" 안내로 인디케이터를 계속 띄운다.
        //    Amethyst 는 이걸 사용자 토글로 넘겼다("This will disable home indicator
        //    locking. You will need to use Guided Access to [have both]").
        //
        //    하지만 바닥 보호가 **실제로 필요한 건 인벤토리·상자가 열려 있을 때뿐**이다.
        //    맨 아랫줄 아이템을 끌어 옮기는 동작이 홈 제스처와 겹치는 그 경우다.
        //    평소 플레이(시점·이동)에서는 바닥 드래그가 아이템 드래그가 아니라 지킬 게 없다.
        //    마우스가 잡혀 있으면(`isGrabbing`) 화면이 안 열린 것이므로 그때만 푼다.
        //
        //    상태 기반이라 깜빡이지 않는다 — 예전에 타이머로 껐다 켰다 했을 때가
        //    깜빡임의 원인이었다. `isGrabbing` 은 화면을 열고 닫을 때만 바뀐다.
        .defersSystemGestures(on: isGrabbing ? [] : .bottom)
        // 게임 안의 "게임 종료" 는 System.exit → C exit() 로 내려온다.
        // 네이티브가 그걸 가로채 앱을 끝내지 않고 이 알림만 보낸다.
        .onReceive(NotificationCenter.default.publisher(for: .FlameGameDidExit)) { _ in
            quitGame(saveFirst: false)
        }
        .sheet(isPresented: $showMenu) {
            InGameMenuView(
                onDumpThreads: { runtime.dumpThreads() },
                resolutionPercent: $settings.resolutionScalePercent,
                onQuit: { quitGame() }
            )
        }
        .onChange(of: controlsVisible) { _, value in
            appSettings.controllerVisible = value
            AppSettingsStore.save(appSettings)
        }
        .onChange(of: settings.resolutionScalePercent) { _, _ in
            // 인게임에서 바꾼 값도 다음 실행까지 남긴다.
            JvmSettingsStore.save(settings)
        }
        .onAppear(perform: startGamepad)
        .onDisappear(perform: teardown)
        .onChange(of: scenePhase) { _, phase in
            // 백그라운드로 가면 게임을 일시정지시킨다 — 안 그러면 돌아왔을 때
            // 눌려 있던 키가 남아 캐릭터가 계속 움직인다.
            if phase != .active { runtime.pause() }
        }
    }

    // MARK: - 부팅

    private func boot(layer: CALayer, size: CGSize) {
        // ⚠️ JIT 가 켜지기 전에 JVM 을 띄우면 코드 캐시를 잡지 못해 부팅 중에 죽는다.
        //    켜질 때까지 기다렸다가 그 다음에 진행한다(PojavLauncher iOS 와 같은 순서).
        guard jit.isEnabled else {
            showJITGate = true
            Task {
                let ok = await jit.enable()
                if ok {
                    showJITGate = false
                    boot(layer: layer, size: size)
                } else if jit.method == .blocked || jit.method == .impossible {
                    // 기다려도 안 풀리는 상태다. 게이트를 띄워둔 채로 사유를 읽게 하고,
                    // 닫는 건 사용자가 정한다 — 바로 닫아버리면 왜 안 되는지 알 수 없다.
                } else {
                    showJITGate = false
                    dismiss()
                }
            }
            return
        }
        startBoot(layer: layer, size: size)
    }

    private func startBoot(layer: CALayer, size: CGSize) {
        do {
            let plan = try GameLauncher(meta: meta, settings: settings, session: auth.session,
                                        screenSize: size).makePlan()
            guiScale = plan.guiScale
            launcher.noteJVMBooted(meta)   // 이 프로세스는 이제 이 인스턴스에 묶인다
            runtime.setEnv(plan.env)
            runtime.attach(layer: layer, size: size)

            Task {
                do {
                    let code = try await runtime.boot(javaHome: plan.javaHome, argv: plan.argv)
                    // JLI_Launch 가 반환했다 = 게임 종료(또는 부팅 실패).
                    if let reason = NativeJavaRuntime.launchFailureReason(code) {
                        bootError = reason
                    } else if code != 0 {
                        bootError = "JVM 이 코드 \(code) 로 종료했습니다. 로그를 확인해 주세요."
                    } else {
                        // 게임이 스스로 끝났다 — JVM 은 이미 죽어서 다시 못 띄운다.
                        quitGame(saveFirst: false)
                    }
                } catch {
                    bootError = error.localizedDescription
                }
            }
            startPolling()
        } catch {
            bootError = error.localizedDescription
        }
    }

    /// grab 상태와 FPS 를 주기적으로 읽는다. 안드로이드는 네이티브가 콜백을 올려줬지만,
    /// 여기서는 dlopen 경계를 콜백 없이 단순하게 유지하려고 폴링으로 뒀다
    /// (초당 5회 — 화면 버튼 모드 전환에는 충분하고 비용은 무시할 만하다).
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                isGrabbing = runtime.isGrabbing
                fps = runtime.fps
                freeMemoryMb = runtime.availableMemoryMb
                // 첫 프레임이 나오면 부팅 오버레이를 내린다.
                if isBooting, runtime.hasRendered { isBooting = false }
            }
        }
        // 런타임이 없으면 프레임이 영영 안 나오므로, 오버레이가 사유를 보여준 채로 남는다.
        if !runtime.isAvailable { bootError = runtime.unavailableReason }
    }

    private func startGamepad() {
        let handler = GamepadHandler(
            sendKey: { runtime.sendKey($0, action: $1, mods: 0) },
            sendMouseButton: { runtime.sendMouseButton($0, action: $1) },
            sendScroll: { runtime.sendScroll($0, $1) },
            moveCursorBy: { dx, dy in surface?.moveLookBy(dx, dy) }
        )
        // ⚠️ 패드가 붙었다고 화면 버튼을 자동으로 숨기지 않는다.
        //    안드로이드가 예전에 그렇게 했다가, 내장 입력장치를 외부 컨트롤러로 오탐한
        //    기기에서 화면 버튼이 아예 안 뜨는 문제가 생겨 명시적 🎮 토글로 바꿨다.
        //    (게다가 숨김 상태가 setting.json 에 저장돼 오탐 한 번이면 영구히 사라진다.)
        handler.start()
        gamepad = handler
    }

    private func teardown() {
        jit.cancel()
        pollTimer?.invalidate()
        pollTimer = nil
        gamepad?.stop()
        gamepad = nil
    }

    /// JVM 이 아직 돌지 않거나 이미 끝난 상태에서 화면만 닫는다.
    private func dismiss() {
        teardown()
        launcher.runningInstance = nil
    }

    /// 게임 화면을 닫고 런처로 돌아간다.
    ///
    /// ⚠️ JVM 은 프로세스당 한 번만 띄울 수 있어서(JLI_Launch) 실제로 죽이지는 못한다.
    ///    대신 일시정지시키고 화면만 내린다. 서피스(레이어)는 `GameSurfaceHolder` 가
    ///    붙잡고 있어서 렌더 스레드가 사라진 레이어를 참조하는 일이 없다 —
    ///    이걸 안 하면 종료 순간 튕긴다.
    ///    다시 실행하면 같은 서피스를 재사용해 이어서 보여준다.
    private func quitGame(saveFirst: Bool = true) {
        teardown()
        if saveFirst { runtime.stop() }   // ESC — 마인크래프트가 월드를 저장한다
        showMenu = false
        // 시트와 fullScreenCover 를 같은 프레임에 내리면 하나가 무시된다 — 한 틱 미룬다.
        DispatchQueue.main.async { launcher.runningInstance = nil }
    }
}

/// 게임에 글자를 흘려 넣는 입력 오버레이.
///
/// 게임이 iOS IME 를 직접 못 받으므로 여기서 받아 GLFW 이벤트로 바꾼다.
/// **치는 대로 바로 보낸다** — 지우면 백스페이스를, 새로 치면 그 글자를 보낸다.
/// 그래야 게임 쪽 입력칸이 우리 칸과 같은 내용을 유지하고, 수정도 그대로 반영된다.
/// (예전에는 버튼을 눌러야 통째로 보내서, 고치면 글자가 중복되거나 어긋났다)
struct ChatInputField: View {
    let onChar: (UInt32) -> Void
    let onBackspace: () -> Void
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    @State private var text = ""
    @State private var sent = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                TextField("입력", text: $text)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(FlameColor.textMain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(submit)
                    .submitLabel(.send)
                    .onChange(of: text) { _, new in
                        let (removed, added) = Self.delta(from: sent, to: new)
                        sent = new
                        for _ in 0..<removed { onBackspace() }
                        for scalar in added.unicodeScalars { onChar(scalar.value) }
                    }
                Button("보내기", action: submit)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FlameColor.primary)
                Button("닫기", action: onDismiss)
                    .font(.system(size: 12))
                    .foregroundStyle(FlameColor.textSub)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .flameCard(radius: 12)
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        // 게임 쪽에는 이미 글자가 다 들어가 있다 — 엔터만 보내면 된다.
        text = ""
        sent = ""
        onSubmit()
    }

    /// 이전에 보낸 것과 지금 내용을 비교해 **지울 개수**와 **새로 넣을 글자**를 낸다.
    /// 공통 접두어까지는 건드리지 않는다.
    static func delta(from old: String, to new: String) -> (removed: Int, added: String) {
        let common = zip(old, new).prefix { $0 == $1 }.count
        return (old.count - common, String(new.dropFirst(common)))
    }
}
