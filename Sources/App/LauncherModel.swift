import SwiftUI
import Observation

/// 런처 화면 전체가 공유하는 상태.
///
/// 안드로이드는 화면마다 ViewModel + Repository + UseCase + Mapper 를 뒀지만
/// (MainViewModel → InstanceRepository → InstanceRepositoryImpl → InstanceMapper →
///  InstanceManager 로 다섯 겹), 실제로 하는 일은 "디스크·네트워크를 읽어 화면에 준다"
/// 하나뿐이다. iOS 쪽은 그 다섯 겹을 걷어내고 서비스를 직접 호출한다.
@Observable
@MainActor
final class LauncherModel {
    var path: [Route] = []

    // ── 목록 ──
    var versions: [VersionEntry] = []
    var isLoadingVersions = false
    var selectedVersion: VersionEntry?
    var selectedInstanceId: String?

    // ── 설치/실행 ──
    var progress = DownloadProgress()
    /// 실행 중인 인스턴스. non-nil 이면 게임 화면이 전체 화면으로 덮인다.
    var runningInstance: InstanceMeta?
    /// "실행 준비 중" 모달에 표시할 인스턴스.
    var launchingInstance: InstanceMeta?
    var alert: AlertMessage?

    /// 이 프로세스에서 JVM 을 띄웠던 인스턴스.
    ///
    /// ⚠️ JVM 은 프로세스당 한 번만 뜬다(JLI_Launch). 같은 인스턴스로 돌아가는 건
    ///    멈춰 둔 JVM 을 깨우면 되지만, **다른 인스턴스는 클래스패스부터 달라서**
    ///    같은 프로세스 안에서는 불가능하다. 앱을 다시 시작해야 한다.
    ///    예전에는 그냥 아무 일도 일어나지 않아서, 눌러도 반응이 없는 것처럼 보였다.
    private(set) var bootedInstanceId: String?



    // MARK: - 재시작을 건너뛰고 이어서 실행하기

    /// 재시작 직전에 "이걸 실행하려던 참이었다"를 남겨 둘 자리.
    ///
    /// JVM 이 프로세스당 한 번뿐이라 다른 버전으로 넘어가려면 앱을 다시 시작해야 하는데,
    /// 그때마다 사용자가 (1) 앱을 다시 열고 (2) JIT 를 다시 붙이고 (3) 버전을 다시 찾아
    /// 눌러야 했다. (1)(2)는 프로세스가 바뀌는 이상 피할 수 없지만 — CS_DEBUGGED 는
    /// 프로세스 속성이라 새 프로세스에는 디버거를 다시 붙여야 한다 — (3)은 없앨 수 있다.
    private static let pendingKey = "flame.pendingLaunchInstanceId"
    private static let pendingAtKey = "flame.pendingLaunchAt"

    /// 재시작 후 이어서 실행할 인스턴스를 적어 둔다.
    static func notePendingLaunch(_ id: String) {
        UserDefaults.standard.set(id, forKey: pendingKey)
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: pendingAtKey)
    }

    /// 적어 둔 인스턴스를 꺼내고 **바로 지운다.**
    ///
    /// ⚠️ 읽자마자 지우는 게 중요하다. 그 인스턴스가 부팅 중에 죽는 버전이면,
    ///    남겨 둘 경우 앱을 열 때마다 같은 크래시로 직행해서 런처 화면에
    ///    영영 못 들어간다. 한 번만 시도하고 실패하면 손을 뗀다.
    static func takePendingLaunch() -> String? {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: pendingKey)
            defaults.removeObject(forKey: pendingAtKey)
        }
        guard let id = defaults.string(forKey: pendingKey) else { return nil }
        // 오래된 기록은 무시한다 — 어제 껐다가 오늘 열었는데 게임이 바로 뜨면 당황스럽다.
        let at = defaults.double(forKey: pendingAtKey)
        guard at > 0, Date.now.timeIntervalSince1970 - at < 600 else { return nil }
        return id
    }

    /// 다른 버전으로 넘어간다 — 예약해 두고, 디버거 도구를 거쳐 새 프로세스로 다시 뜬다.
    ///
    /// 자바 가상머신은 프로세스당 한 번만 뜨므로 버전을 바꾸려면 프로세스가 새로 떠야 하고,
    /// JIT 는 프로세스 속성이라 그 새 프로세스에는 디버거를 다시 붙여야 한다. 둘 다 피할 수
    /// 없다면 **손으로 하지 않게** 만드는 것이 남는 일이다.
    ///
    /// 예전에는 "앱을 완전히 종료했다 다시 여세요" 안내를 띄우고 끝이었다. 사용자는
    /// 앱을 죽이고, 아이콘을 찾아 누르고, JIT 도구를 거치고, 버전을 다시 찾아 눌러야 했다.
    /// 이제 그 네 단계를 한 번의 확인으로 대신한다.
    func switchTo(_ meta: InstanceMeta) {
        Self.notePendingLaunch(meta.id)
        // 요청이 실제로 나갔을 때만 종료한다. 도구가 없는데 앱만 죽으면
        // 사용자는 아무 설명 없이 앱이 사라지는 것만 겪는다.
        guard FlameNativeRequestDebuggerJITForRelaunch() else {
            alert = AlertMessage(
                title: String(localized: "앱을 다시 열어주세요"),
                message: "\(meta.name) 로 준비해 뒀습니다. 앱을 완전히 종료했다 다시 열면 바로 이어집니다."
            )
            return
        }
        // URL 전달과 화면 전환이 끝날 틈을 준다. 곧바로 exit 하면 요청이 유실된다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { exit(0) }
    }

    /// 앱이 뜬 뒤 한 번 부른다. 재시작 직전에 고른 인스턴스가 있으면 그대로 이어서 실행한다.
    func resumePendingLaunchIfNeeded() {
        guard runningInstance == nil, bootedInstanceId == nil,
              let id = Self.takePendingLaunch(),
              let meta = InstanceStore.shared.instances.first(where: { $0.id == id })
        else { return }
        selectedInstanceId = meta.id
        launch(meta)
    }

    /// 게임 화면이 JVM 을 실제로 띄울 때 알려준다.
    func noteJVMBooted(_ meta: InstanceMeta) {
        if bootedInstanceId == nil { bootedInstanceId = meta.id }
        // 방금 돌린 버전이 목록 맨 위로 오게 기록한다. 게임에서 나왔을 때
        // 한가운데서 다시 찾지 않아도 된다.
        InstanceStore.shared.notePlayed(meta)
    }

    var instances: [InstanceMeta] { InstanceStore.shared.instances }

    /// 화면에 띄울 알림.
    ///
    /// ⚠️ 알림은 **이 하나로만** 띄운다. 예전에는 재시작 안내를 별도 `.alert` 로 달았는데,
    ///    SwiftUI 는 한 뷰에 여러 `.alert` 를 붙이면 나중 것이 앞의 것을 덮어서
    ///    **앞의 알림이 영영 안 뜬다.** 배경 앵커(Color.clear)로 피해 보려 했지만
    ///    그것도 안 떴다. 채널을 하나로 두면 이 문제 자체가 생기지 않는다.
    struct AlertMessage: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        /// 있으면 확인 버튼이 이 이름으로 바뀌고, 눌렀을 때 이걸 실행한다.
        var confirmTitle: String?
        var confirm: (() -> Void)?
        /// 물러날 수 있어야 하는가(취소 버튼).
        var cancellable: Bool = false
    }

    /// 버전 목록을 가져오지 못한 이유(있으면). 목록이 빈 채로 두지 않고 화면에 보여준다.
    var versionLoadError: String?

    func loadVersions() async {
        guard !isLoadingVersions else { return }
        isLoadingVersions = true
        versions = await VersionService.versions()
        versionLoadError = versions.isEmpty
            ? (VersionService.lastError?.localizedDescription ?? String(localized: "버전 목록을 가져오지 못했습니다"))
            : nil
        isLoadingVersions = false
        if selectedVersion == nil {
            selectedVersion = versions.first { $0.isRelease }
        }
    }

    // MARK: - 설치

    /// 버전 + 로더를 골라 새 인스턴스를 만들고 실행까지 간다.
    /// 안드로이드 MainActivity 의 downloadAndPlay / launchFabric / launchForge 를 하나로 합쳤다 —
    /// 셋이 로더 설치 호출 한 줄만 다르고 나머지가 같은 복붙이었다.
    func installAndPlay(version: VersionEntry, loader: ModLoader, loaderVersion: String?) async {
        let baseId = loader == .vanilla
            ? InstanceStore.vanillaId(version.id)
            : InstanceStore.loaderId(loader.rawValue, mc: version.id, loaderVersion: loaderVersion ?? "")
        let id = InstanceStore.withToken(baseId, InstanceStore.newToken())

        var meta = InstanceMeta(
            id: id,
            name: loader == .vanilla ? "Minecraft \(version.id)" : "\(loader.displayName) \(version.id)",
            type: loader == .vanilla ? .vanilla : .fabric,
            mcVersion: version.id
        )
        Paths.ensureDir(meta.dir)

        do {
            let onProgress: @Sendable (DownloadProgress) -> Void = { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }

            let prepared = try await MinecraftDownloader(
                instanceDir: meta.dir, versionEntry: version, onProgress: onProgress
            ).prepare()
            meta.assetIndexId = prepared.assetIndexId
            meta.mainClass = prepared.mainClass
            // 1.12 이하는 매니페스트의 minecraftArguments 를 게임 인자로 그대로 쓴다.
            if let legacy = prepared.minecraftArguments {
                meta.gameArgs = legacy.split(separator: " ").map(String.init)
            }

            if loader != .vanilla, let loaderVersion {
                let installer = LoaderInstaller(instanceDir: meta.dir, onProgress: onProgress)
                if let result = try await installer.install(loader, mcVersion: version.id,
                                                            loaderVersion: loaderVersion) {
                    meta.loaderType = loader.rawValue
                    meta.loaderVersion = loaderVersion
                    meta.mainClass = result.mainClass
                    meta.extraJars = result.extraJars
                    meta.gameJvmArgs = result.gameJvmArgs
                    meta.gameArgs += result.gameArgs
                }
            }

            InstanceStore.shared.save(meta)
            progress = DownloadProgress(phase: .done)
            selectedInstanceId = meta.id
            launch(meta)
        } catch {
            progress = DownloadProgress(phase: .error, error: error.localizedDescription)
            alert = AlertMessage(title: String(localized: "설치 실패"), message: error.localizedDescription)
        }
    }

    // MARK: - 실행

    func launch(_ meta: InstanceMeta) {
        // 이미 다른 인스턴스로 JVM 을 띄운 프로세스라면 여기서 막고 재시작을 안내한다.
        if let booted = bootedInstanceId, booted != meta.id {
            let name = InstanceStore.shared.instances.first { $0.id == booted }?.name ?? booted
            print("[Flame] 버전 전환 필요: \(name) -> \(meta.name)")
            let body = "이번 실행에서는 \(name) 을(를) 이미 띄웠습니다. "
                + String(localized: "자바 가상머신은 앱 실행당 한 번만 뜰 수 있어서 앱이 새로 떠야 합니다.\n\n")
                + "전환을 누르면 JIT 도구를 거쳐 알아서 다시 뜨고, \(meta.name) 가 바로 실행됩니다."
            alert = AlertMessage(
                title: "\(meta.name) 로 전환할까요?",
                message: body,
                confirmTitle: String(localized: "전환"),
                confirm: { [weak self] in self?.switchTo(meta) },
                cancellable: true
            )
            return
        }
        launchingInstance = meta
        // 게임 화면 전환에 한 프레임 주고 나서 모달을 띄운다 — 안드로이드에서
        // Activity 전환 직전에 팝업이 깜빡이던 것과 같은 처리.
        Task { @MainActor in
            runningInstance = meta
            try? await Task.sleep(for: .milliseconds(300))
            launchingInstance = nil
        }
    }

    func deleteInstance(_ id: String) {
        InstanceStore.shared.delete(id: id)
        if selectedInstanceId == id { selectedInstanceId = instances.first?.id }
    }
}
