import SwiftUI

/// 왼쪽 메뉴. 마인크래프트 런처의 좌측 사이드바에 해당한다.
///
/// ⚠️ 두 종류가 섞여 있다:
///   - `instances` / `notes` 는 **오른쪽 칸을 바꾼다**(선택 상태로 표시)
///   - `modpacks` / `settings` 는 **기존 전체 화면을 민다**(오른쪽 꺾쇠로 표시)
///
///   후자를 인라인으로 넣지 않는 이유: 그 화면들의 동작 버튼(설정의 저장·초기화)이
///   네비게이션 바 툴바에 있는데, 메인 화면은 네비바를 숨긴다. 그대로 끼우면
///   버튼이 통째로 사라진다.
enum MainSection: String, CaseIterable, Identifiable {
    case instances, modpacks, settings, keyboard, terracotta, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instances: return "인스턴스 선택"
        case .modpacks:  return "모드팩 설치"
        case .settings:  return "옵션 · 렌더러"
        case .keyboard:  return "키보드 편집"
        case .terracotta: return "온라인 LAN"
        case .notes:     return "업데이트 노트"
        }
    }

    var subtitle: String {
        switch self {
        case .instances: return "버전을 고르고 실행"
        case .modpacks:  return "CurseForge · Modrinth"
        case .settings:  return "메모리 · 해상도 · 렌더러"
        case .keyboard:  return "화면 버튼 배치"
        case .terracotta: return "방 코드로 함께 플레이"
        case .notes:     return "저장소 README"
        }
    }

    /// SF Symbols 로 통일한다 — 기기 폰트라 어떤 해상도에서도 선명하고,
    /// 마인크래프트 텍스처를 번들하지 않아도 된다(저작권 문제 회피).
    var icon: String {
        switch self {
        case .instances: return "square.stack.3d.up.fill"
        case .modpacks:  return "shippingbox.fill"
        case .settings:  return "slider.horizontal.3"
        case .keyboard:  return "keyboard.fill"
        case .terracotta: return "antenna.radiowaves.left.and.right"
        case .notes:     return "doc.text.fill"
        }
    }

    /// true 면 오른쪽 칸을 바꾸고, false 면 전체 화면을 민다.
    var showsInDetail: Bool { self == .instances || self == .notes }

    var route: Route? {
        switch self {
        case .modpacks: return .contentBrowser
        case .settings: return .settings
        case .keyboard: return .keyLayout
        case .terracotta: return .terracotta
        default:        return nil
        }
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case installed, release, all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .installed: return "설치됨"
        case .release:   return "정식"
        case .all:       return "전체"
        }
    }

    /// SF Symbols 로 통일 — 이모지는 기기/OS 마다 모양이 달라 톤이 깨진다.
    var icon: String {
        switch self {
        case .installed: return "internaldrive.fill"
        case .release:   return "checkmark.seal.fill"
        case .all:       return "square.grid.2x2.fill"
        }
    }
}

/// 안드로이드 `MainScreen` 이식.
///
/// 레이아웃 규칙도 그대로 옮겼다:
///  - iPad: 좌 목록(0.62) + 우 실행 패널(0.38)
///  - iPhone: 상단 52pt 앱바 + 목록 + 하단 실행 바 (목록에 세로 공간을 최대한 내준다)
struct MainView: View {
    @Environment(LauncherModel.self) private var launcher
    @Environment(AuthStore.self) private var auth

    @State private var tab: MainTab = .installed
    @State private var section: MainSection = .instances
    @State private var showVersionPicker = false
    @State private var showLoaderSheet = false
    @State private var instances = InstanceStore.shared.instances

    private var tablet: Bool { Sizing.isTablet }

    var body: some View {
        @Bindable var launcher = launcher

        ZStack {
            FlameColor.bgDark.ignoresSafeArea()

            VStack(spacing: 0) {
                if tablet { ProfileHeader() } else { MobileTopBar() }
                splitBody
            }
            // ⚠️ 예전에는 ZStack 위에 겹쳐 올리고, 목록 끝에 `Color.clear.frame(height: 80)`
            //    같은 상수로 자리를 비워 뒀다. 그 상수가 바 높이와 어긋나면 목록 마지막 줄이
            //    바에 가려 끝까지 안 내려간다(실제로 그랬다).
            //    safeAreaInset 으로 주면 SwiftUI 가 스크롤 인셋을 알아서 맞춘다 — 상수가 필요 없다.
            //    ⚠️ 설치됨 탭에서는 띄우지 않는다. 목록 아래 InstalledPanel 이 이미 같은 것을
            //       — 인스턴스 이름, MC 버전, ▶실행 — 전부 들고 있어서 두 번 나온다.
            //       거긴 렌더러 선택까지 있으니 그쪽을 남긴다.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !tablet && tab != .installed { MobileBottomBar(tab: tab, onPlay: play) }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showVersionPicker) {
            VersionPickerSheet(versions: launcher.versions) { version in
                showVersionPicker = false
                install(version)
            }
            .environment(launcher)
            .environment(auth)
        }
        .sheet(isPresented: $showLoaderSheet) {
                // ⚠️ 시트/커버는 SwiftUI 가 **별도의 PresentationHostingController** 로 띄운다.
                //    우리는 환경을 루트 UIHostingController 바깥에서 걸기 때문에(AppDelegate),
                //    iOS 는 알아서 복사해 주지만 맥('Designed for iPad')은 안 해준다 —
                //    그쪽에서 @Environment(LauncherModel.self) 를 읽는 순간
                //    "No Observable object of type LauncherModel found" 로 죽는다.
                //    모달 경계에서는 직접 넣어준다.
            Group {
                if let version = launcher.selectedVersion {
                    LoaderSelectSheet(version: version) { loader, loaderVersion in
                        showLoaderSheet = false
                        Task { await launcher.installAndPlay(version: version, loader: loader,
                                                             loaderVersion: loaderVersion) }
                    }
                }
            }
            .environment(launcher)
            .environment(auth)
        }
        .overlay {
            if let meta = launcher.launchingInstance { LaunchingDialog(meta: meta) }
        }
        // JVM 은 프로세스당 한 번뿐이라, 다른 인스턴스로 넘어가려면 앱을 다시 시작해야 한다.
        // 그냥 막고 끝내면 "눌러도 아무 일이 없다"가 되므로 이유와 방법을 같이 준다.
        //
        // ⚠️ **자기 앵커(Color.clear)에서 띄운다.** 한 뷰에 .alert 를 여러 개 붙이면
        //    나중 것이 앞의 것을 덮어서 앞의 알림은 영영 안 뜬다. 아래에 .alert 가 둘 더
        //    있어서, 이걸 같은 자리에 두면 재시작 안내가 **뜨지 않는다** — 막으려던
        //    "눌러도 아무 일이 없다"가 그대로 재현된다(실제로 그랬다).
        .background {
            Color.clear.alert(item: $launcher.restartRequest) { request in
                Alert(
                    title: Text("앱을 다시 시작해야 합니다"),
                    message: Text("""
                        이번 실행에서는 \(request.booted) 을(를) 이미 띄웠습니다.
                        자바 가상머신은 앱 실행당 한 번만 뜰 수 있어서, \(request.target.name) 로 \
                        바꾸려면 앱을 완전히 종료했다가 다시 열어야 합니다.
                        """),
                    primaryButton: .destructive(Text("지금 종료")) {
                        // 다시 열었을 때 이 인스턴스로 곧장 이어지게 적어 둔다 —
                        // 사용자가 버전을 다시 찾아 누르는 단계를 없앤다.
                        LauncherModel.notePendingLaunch(request.target.id)
                        exit(0)
                    },
                    secondaryButton: .cancel(Text("나중에"))
                )
            }
        }
        .alert(item: $launcher.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message),
                  dismissButton: .default(Text("확인")))
        }
        // 로그인 실패는 조용히 삼키면 안 된다 — 사용자는 "눌렀는데 아무 일도 안 일어남" 만 겪는다.
        .alert("로그인 실패", isPresented: .init(
            get: { auth.error != nil },
            set: { if !$0 { auth.error = nil } }
        )) {
            Button("확인") { auth.error = nil }
        } message: {
            Text(auth.error ?? "")
        }
        .overlay {
            if auth.isBusy { LoginProgressOverlay(step: auth.progress) }
        }
        .onAppear {
            InstanceStore.shared.reload()
            instances = InstanceStore.shared.instances
            tab = instances.isEmpty ? .release : .installed
            if launcher.selectedInstanceId == nil { launcher.selectedInstanceId = instances.first?.id }
        }
        .onChange(of: launcher.runningInstance) { _, running in
            // 게임에서 돌아오면 목록을 다시 읽는다(세이브/모드가 늘었을 수 있다).
            if running == nil {
                InstanceStore.shared.reload()
                instances = InstanceStore.shared.instances
            }
        }
    }

    // MARK: - 탭

    /// ⚠️ 이 탭바는 화면 전체가 아니라 **1/6 칸 안에** 들어간다. 예전처럼 글자 + 개수를
    ///    한 줄에 세 개 늘어놓으면 "정식 출…", "전체 (9…" 처럼 잘린다(실제로 그랬다).
    ///    아이콘 + 짧은 라벨로 줄이고, 개수는 아래 줄에 작게 둔다.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { item in
                let selected = tab == item
                let count = count(for: item)
                Button { tab = item } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.icon).font(.system(size: 12))
                            .foregroundStyle(selected ? .white : FlameColor.textSub)
                        Text(item.label)
                            .font(.system(size: 10, weight: selected ? .bold : .regular))
                            .foregroundStyle(selected ? .white : FlameColor.textSub)
                        Text(count > 0 ? "\(count)" : " ")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(selected ? .white.opacity(0.75) : FlameColor.textSub.opacity(0.6))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .flameSelectableCard(selected: selected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func count(for item: MainTab) -> Int {
        switch item {
        case .installed: return instances.count
        case .release:   return launcher.versions.count { $0.isRelease }
        case .all:       return launcher.versions.count
        }
    }

    // MARK: - 본문 (1 : 5 분할)

    /// 마인크래프트 런처와 같은 배치 — 왼쪽 좁은 칸에서 버전을 고르고,
    /// 오른쪽 넓은 칸에 업데이트 노트를 띄운다.
    ///
    /// ⚠️ 앱 전체가 가로 고정이라(orientationMask = .landscape) 1:5 가 성립한다.
    ///    세로였다면 왼쪽이 종잇장이 된다.
    private var splitBody: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                sidebar
                    // 2 : 4 — 메뉴 이름이 잘리지 않을 만큼은 줘야 한다.
                    //         1/6 일 때는 "정식 출…" 처럼 전부 잘렸다.
                    .frame(width: max(geo.size.width / 3, 210))

                Rectangle()
                    .frame(width: 1)
                    .foregroundStyle(FlameColor.bgBorder)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 왼쪽 메뉴

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: Sizing.isTablet ? 6 : 5) {
                ForEach(MainSection.allCases) { item in
                    SectionRow(section: item, selected: section == item) {
                        if let route = item.route {
                            launcher.path.append(route)
                        } else {
                            section = item
                        }
                    }
                }
            }
            // ⚠️ 위쪽 여백은 두지 않는다 — 헤더 바로 아래라 이중으로 떠 보인다.
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .scrollContentBackground(.hidden)
        .background(FlameColor.bgSurface)
    }

    // MARK: - 오른쪽 본문

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .notes:
            ReleaseNotesView()
        default:
            VStack(spacing: 0) {
                tabBar
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if launcher.isLoadingVersions && tab != .installed {
            Spacer()
            ProgressView().tint(FlameColor.primary)
            Spacer()
        } else if launcher.versions.isEmpty, tab != .installed {
            // ⚠️ 예전에는 그냥 빈 목록이었다. 앱 시작 때 한 번 실패하면 이유도 없이
            //    아무것도 안 뜨고, 모드팩 설치까지 조용히 막혔다(베이스 버전을 여기서 찾는다).
            Spacer()
            VStack(spacing: 10) {
                Text("🛜").font(.system(size: 40))
                Text("버전 목록을 가져오지 못했어요")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                if let reason = launcher.versionLoadError {
                    Text(reason)
                        .font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
                        .multilineTextAlignment(.center)
                }
                Button("다시 시도") { Task { await launcher.loadVersions() } }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FlameColor.primary)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .flameCard(fill: FlameColor.bgItem, radius: 10)
                    .flameTappable()
            }
            .padding(32)
            Spacer()
        } else {
            // ⚠️ 예전에는 태블릿에서 오른쪽에 실행 패널(sidePanel)을 뒀다. 이제 그 자리는
            //    업데이트 노트가 쓰므로, 실행은 목록 아래 고정 바에서 한다.
            // ⚠️ 정식·전체 탭에는 아래 띠를 두지 않는다. 거기서 고를 게 없기 때문이다 —
            //    행을 누르면 바로 설치로 넘어간다. 실행 대상은 설치됨 탭이 갖는다.
            VStack(spacing: 0) {
                list
                if tab == .installed { sidePanel }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        @Bindable var launcher = launcher

        if tab == .installed {
            InstancesList(
                instances: instances,
                selectedId: $launcher.selectedInstanceId,
                onOpenSettings: { launcher.path.append(.instanceSettings($0.id)) }
            )
        } else {
            VersionsList(
                versions: tab == .release ? launcher.versions.filter(\.isRelease) : launcher.versions,
                onPick: install
            )
        }
    }

    /// ⚠️ 호출부가 이미 `tab == .installed` 안에 있다. 여기서 또 분기하면 죽은 가지가 생긴다
    ///    (실제로 정식·전체용 패널이 하나 더 있었는데 영원히 그려지지 않았다).
    private var sidePanel: some View {
        InstalledPanel(
            count: instances.count, selected: selectedInstance,
            onLaunch: play,
            onChangeVersion: { showVersionPicker = true },
            onChangeRenderer: { renderer in
                guard let id = launcher.selectedInstanceId else { return }
                InstanceStore.shared.updateRendererId(id, rendererId: renderer?.rawValue)
                instances = InstanceStore.shared.instances
            }
        )
    }

    private var selectedInstance: InstanceMeta? {
        instances.first { $0.id == launcher.selectedInstanceId }
    }

    // MARK: - 실행

    /// 설치됨 탭의 실행 버튼.
    private func play() {
        guard auth.isLoggedIn else {
            Task { await auth.login() }
            return
        }
        if let meta = selectedInstance { launcher.launch(meta) }
    }

    /// 정식·전체 탭에서 버전을 눌렀을 때 — 로더를 고르고 새 인스턴스를 만든다.
    /// 설치됨 탭의 "선택됨" 카드를 눌렀을 때도 같은 곳으로 온다(버전 바꿔 다시 설치).
    private func install(_ version: VersionEntry) {
        guard auth.isLoggedIn else {
            Task { await auth.login() }
            return
        }
        launcher.selectedVersion = version
        showLoaderSheet = true
    }
}

// MARK: - 상단바 (iPhone)

/// 안드로이드가 태블릿 배너를 축소해 쓰던 걸 버리고 폰 전용으로 새로 만든 52pt 앱바.
/// 리스트에 세로 공간을 최대한 내주는 게 목표다.
private struct MobileTopBar: View {
    @Environment(LauncherModel.self) private var launcher
    @Environment(AuthStore.self) private var auth

    var body: some View {
        @Bindable var launcher = launcher

        HStack(spacing: 0) {
            // ⚠️ 원본 PNG 는 711×711 중 실제 그림이 190×311 뿐이고 나머지는 투명이었다.
            //    그래서 20pt 로 그려도 불꽃이 7pt 남짓밖에 안 됐다 — 자산 자체를 잘라 두고
            //    표시 크기도 키운다.
            Image("logo").resizable().scaledToFit().frame(width: 28, height: 28)
            Spacer().frame(width: 8)
            Text("FlameLauncher")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(FlameColor.textMain)
                .lineLimit(1)
            Spacer()

            // ⚠️ 콘텐츠·설정·키보드는 전부 왼쪽 메뉴로 옮겼다 — 상단에 남겨 두면
            //    같은 곳으로 가는 입구가 두 개가 된다.

            ProfileAvatar(size: 32)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(FlameColor.bgSurface)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(FlameColor.bgBorder),
                 alignment: .bottom)
    }

}

// MARK: - 상단 배너 (iPad)

private struct ProfileHeader: View {
    @Environment(LauncherModel.self) private var launcher
    @Environment(AuthStore.self) private var auth

    var body: some View {
        @Bindable var launcher = launcher

        HStack(spacing: 16) {
            ProfileAvatar(size: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(auth.isLoggedIn ? (auth.username ?? "") : "로그인이 필요합니다")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                Text(auth.isLoggedIn ? "Microsoft 계정으로 로그인됨" : "탭해서 Microsoft 계정으로 로그인")
                    .font(.system(size: 12))
                    .foregroundStyle(FlameColor.textSub)
            }

            Spacer()

            // ⚠️ 콘텐츠·설정·키보드는 전부 왼쪽 메뉴로 옮겼다 — 상단에 남겨 두면
            //    같은 곳으로 가는 입구가 두 개가 된다.
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            LinearGradient(colors: [FlameColor.dark.opacity(0.55), FlameColor.bgSurface],
                           startPoint: .leading, endPoint: .trailing)
        )
        .overlay(Rectangle().frame(height: 1).foregroundStyle(FlameColor.bgBorder),
                 alignment: .bottom)
    }

}

/// 로그인 진행 중 오버레이. 5단계라 그냥 도는 스피너보다 어디쯤인지 보여주는 게 낫다.
private struct LoginProgressOverlay: View {
    let step: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(FlameColor.primary)
                Text(step ?? "로그인 중…")
                    .font(.system(size: 13))
                    .foregroundStyle(FlameColor.textMain)
            }
            .padding(24)
            .flameCard(radius: 14)
        }
    }
}

/// 스킨 얼굴 아바타 + 로그인 메뉴. 안드로이드 `loadSkinFace` + DropdownMenu 대응.
private struct ProfileAvatar: View {
    @Environment(AuthStore.self) private var auth
    let size: CGFloat

    var body: some View {
        Menu {
            if auth.isLoggedIn {
                Text(auth.username ?? "")
                Button("로그아웃", role: .destructive) { auth.logout() }
            } else {
                Button("로그인") { Task { await auth.login() } }
            }
        } label: {
            ZStack {
                if let url = auth.session?.faceURL {
                    AsyncImage(url: url) { image in
                        image.resizable().interpolation(.none)   // 스킨은 픽셀 아트 — 보간 끄기
                    } placeholder: {
                        Text("👤").font(.system(size: size * 0.4))
                    }
                } else {
                    Text(auth.isLoggedIn ? (auth.username?.prefix(1).uppercased() ?? "?") : "👤")
                        .font(.system(size: size * 0.4, weight: .bold, design: .monospaced))
                        .foregroundStyle(FlameColor.light)
                }
            }
            .frame(width: size, height: size)
            // ⚠️ flameCard 는 배경과 테두리만 그린다 — **자르지 않는다.**
            //    그래서 스킨 이미지가 둥근 모서리 밖으로 삐져나왔다. 직접 잘라준다.
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .flameCard(fill: FlameColor.bgSurface,
                       stroke: auth.isLoggedIn ? FlameColor.primary : FlameColor.bgBorder,
                       radius: 8)
        }
    }
}

// MARK: - 목록

/// ⚠️ 여기서는 버전을 **고르는 게 아니라 설치한다.** 예전에는 행을 누르면 선택 상태만
///    바뀌고, 아래 띠에서 다시 Play 를 눌러야 했다 — 한 동작을 두 곳에 나눠 둔 셈이었다.
///    누르면 바로 로더 선택으로 넘어간다. 그래서 선택 표시도, 아래 띠도 없다.
private struct VersionsList: View {
    let versions: [VersionEntry]
    let onPick: (VersionEntry) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(versions) { version in
                    VersionRow(version: version, selected: false)
                        .onTapGesture { onPick(version) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct VersionRow: View {
    let version: VersionEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(version.id)
                .font(.system(size: Sizing.pick(14, 12, 10), weight: .bold))
                .foregroundStyle(FlameColor.textMain)
                .lineLimit(1)

            Text(version.type)
                .font(.system(size: Sizing.pick(10, 9, 8), weight: .medium))
                .foregroundStyle(tagColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tagColor.opacity(0.15), in: Capsule())

            if !VersionRules.isSupported(version.id) {
                Text("미지원")
                    .font(.system(size: Sizing.pick(10, 9, 8)))
                    .foregroundStyle(FlameColor.red)
            }

            Spacer()

            if selected {
                Text("✓").font(.system(size: Sizing.pick(18, 15, 13), weight: .bold))
                    .foregroundStyle(FlameColor.primary)
            }
        }
        .padding(.horizontal, Sizing.pick(14, 10, 8))
        .padding(.vertical, Sizing.pick(12, 8, 7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameSelectableCard(selected: selected)
        .contentShape(Rectangle())
    }

    private var tagColor: Color {
        if version.isRelease { return FlameColor.tagRelease }
        if version.isSnapshot { return FlameColor.tagSnapshot }
        return FlameColor.tagOld
    }
}

private struct InstancesList: View {
    let instances: [InstanceMeta]
    @Binding var selectedId: String?
    let onOpenSettings: (InstanceMeta) -> Void

    var body: some View {
        if instances.isEmpty {
            VStack(spacing: 6) {
                Text("📭").font(.system(size: 48))
                Text("설치된 인스턴스가 없어요")
                    .font(.system(size: 13)).foregroundStyle(FlameColor.textSub)
                Text("버전 탭에서 원하는 버전을 골라 내려받으세요")
                    .font(.system(size: 11))
                    .foregroundStyle(FlameColor.textSub.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(instances) { meta in
                        InstanceRow(meta: meta, selected: meta.id == selectedId,
                                    onOpenSettings: { onOpenSettings(meta) })
                            .onTapGesture { selectedId = meta.id }
                    }
                }
                .padding(.horizontal, 16)
                // ⚠️ 위쪽 여백은 두지 않는다 — 탭바 바로 아래라 이중으로 떠 보인다.
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct InstanceRow: View {
    let meta: InstanceMeta
    let selected: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: Sizing.isCompact ? 8 : 12) {
            InstanceIcon(meta: meta, size: Sizing.pick(28, 22, 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name)
                    .font(.system(size: Sizing.pick(14, 12, 10), weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                    .lineLimit(1)
                // 좁은 화면에서는 "MC {버전} · {로더}" 가 한 줄에 안 들어가 잘린다 — 로더만.
                Text(Sizing.isCompact ? meta.loaderLabel : "MC \(meta.mcVersion) · \(meta.loaderLabel)")
                    .font(.system(size: Sizing.pick(11, 9, 8)))
                    .foregroundStyle(FlameColor.textSub)
                    .lineLimit(1)
            }

            Spacer()

            if selected {
                Text("✓").font(.system(size: Sizing.pick(18, 15, 13), weight: .bold))
                    .foregroundStyle(FlameColor.primary)
            }

            Button(action: onOpenSettings) {
                Text("⚙️").font(.system(size: Sizing.pick(14, 12, 10)))
                    .frame(width: Sizing.pick(32, 28, 24), height: Sizing.pick(32, 28, 24))
                    .flameCard(fill: FlameColor.bgDark, radius: 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Sizing.pick(14, 10, 8))
        .padding(.vertical, Sizing.pick(12, 8, 7))
        .flameSelectableCard(selected: selected)
        .contentShape(Rectangle())
    }
}

/// 인스턴스 아이콘. 다운로드한 콘텐츠 로고가 있으면 그것, 없으면 로더 기본 이모지.
struct InstanceIcon: View {
    let meta: InstanceMeta
    let size: CGFloat

    var body: some View {
        Group {
            if let url = meta.iconURL, FileManager.default.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let asset = meta.fallbackAsset {
                // 정사각 캔버스에 담아 둔 그림이라 비율을 지켜 넣는다.
                Image(asset).resizable().scaledToFit()
            } else {
                Text(meta.fallbackSymbol).font(.system(size: size * 0.8))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - 실행 패널

/// 설치됨 탭의 실행 줄. 폰에서도 이게 유일하다 — 예전엔 아래에 MobileBottomBar 가
/// 같은 내용(이름 · MC 버전 · ▶실행)을 한 번 더 그려서 둘이 겹쳐 있었다.
private struct InstalledPanel: View {
    @Environment(AuthStore.self) private var auth
    let count: Int
    let selected: InstanceMeta?
    let onLaunch: () -> Void
    let onChangeVersion: () -> Void
    let onChangeRenderer: (Renderer?) -> Void

    /// 한 줄에 놓이는 카드 셋(버전 · 렌더러 · 실행)의 공통 높이.
    private static var rowHeight: CGFloat { Sizing.isTablet ? 46 : 40 }

    // ⚠️ 예전에는 세로로 쌓아 Spacer 로 늘였다. 목록 아래 띠로 들어가면서 렌더러 행이
    //    화면 밖으로 밀려 **스크롤해야 보였다.** 한 줄에 담아 항상 보이게 한다.
    var body: some View {
        if let selected {
            HStack(alignment: .center, spacing: 12) {
                // 버전 변경 입구
                Button(action: onChangeVersion) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(FlameColor.textMain)
                                .lineLimit(1)
                            Text("MC \(selected.mcVersion) · \(selected.loaderLabel)")
                                .font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
                                .lineLimit(1)
                        }
                        // ⚠️ 글자 바로 뒤가 아니라 **오른쪽 끝**에 붙인다. 이름 길이에 따라
                        //    아이콘 위치가 들쭉날쭉하면 옆 카드들과 줄이 안 맞아 보인다.
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(FlameColor.primary)
                    }
                    .padding(.horizontal, 12)
                    // 옆 카드(렌더러·실행)와 같은 높이. 안쪽 여백으로 높이를 정하면
                    // 줄 수가 다른 카드끼리 몇 pt 씩 어긋난다.
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight,
                           maxHeight: Self.rowHeight, alignment: .leading)
                    .flameCard(fill: FlameColor.bgDark, radius: 10)
                }
                .buttonStyle(.plain)

                rendererRow(for: selected)
                    .frame(width: Sizing.isTablet ? 190 : 150)

                Button(auth.isLoggedIn ? "▶  실행" : "로그인", action: onLaunch)
                    .buttonStyle(FlameButtonStyle(height: Self.rowHeight, radius: 10))
                    .font(.system(size: Sizing.isTablet ? 15 : 13, weight: .bold))
                    .frame(width: Sizing.isTablet ? 130 : 96)
            }
            .padding(.horizontal, Sizing.isTablet ? 16 : 10)
            .padding(.vertical, Sizing.isTablet ? 12 : 8)
        } else {
            Text("왼쪽 목록에서 인스턴스를 선택하세요")
                .font(.system(size: 12)).foregroundStyle(FlameColor.textSub)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
        }
    }

    /// 이 인스턴스가 실제로 쓸 렌더러. 여기서 바로 바꿀 수 있어야 한다 —
    /// 예전에는 인스턴스 설정 화면까지 들어가야 보였는데, 셰이더가 되는지 안 되는지가
    /// 렌더러에 달려 있어서 가장 자주 만지는 값이다.
    @ViewBuilder
    private func rendererRow(for meta: InstanceMeta) -> some View {
        let current = meta.rendererId.flatMap(Renderer.init(rawValue:))
        let effective = RendererStore.resolve(for: meta)

        Menu {
            Button { onChangeRenderer(nil) } label: {
                Label("전역 기본 (\(RendererStore.load().displayName))",
                      systemImage: current == nil ? "checkmark" : "")
            }
            ForEach(Renderer.allCases) { item in
                Button { onChangeRenderer(item) } label: {
                    Label("\(item.emoji) \(item.displayName)",
                          systemImage: current == item ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(FlameColor.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("렌더러").font(.system(size: 10)).foregroundStyle(FlameColor.textSub)
                    Text(current == nil ? "\(effective.displayName) (전역 기본)" : effective.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlameColor.textMain)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlameColor.textSub)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight,
                   maxHeight: Self.rowHeight, alignment: .leading)
            .flameCard(fill: FlameColor.bgDark, radius: 10)
        }
    }

}

/// 진행 상태 한 줄 — 문구 + 얇은 막대.
///
/// 총 개수를 모르는 단계(매니페스트 · 클라이언트)에서는 퍼센트가 의미 없으므로
/// 막대를 부정형(indeterminate)으로 두지 않고 아예 감춘다. 0%에 멈춘 막대는
/// "멈췄다"로 읽힌다.
/// ⚠️ private 이 아니다 — ContentDetailView 도 쓴다.
struct ProgressRow: View {
    let progress: DownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(progress.label)
                    .font(.system(size: 10))
                    .foregroundStyle(progress.phase == .error ? FlameColor.red : FlameColor.textSub)
                    .lineLimit(1)
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.percent)%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(FlameColor.textSub)
                }
            }

            if progress.total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(FlameColor.bgItem)
                        Capsule().fill(FlameColor.primary)
                            .frame(width: geo.size.width * progress.fraction)
                    }
                }
                .frame(height: 3)
            }
        }
    }
}

// MARK: - 하단바 (iPhone)

/// 안드로이드에서 버전용 BottomPanel / 인스턴스용 InstanceLaunchBar 로 나뉘어 있던 걸
/// 하나로 합쳤다. 56pt 고정, 왼쪽엔 선택 항목 한 줄, 오른쪽엔 Play 하나.
private struct MobileBottomBar: View {
    @Environment(LauncherModel.self) private var launcher
    @Environment(AuthStore.self) private var auth
    let tab: MainTab
    let onPlay: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if launcher.progress.isActive || launcher.progress.phase == .error {
                ProgressRow(progress: launcher.progress)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(FlameColor.textMain)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(FlameColor.textSub)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onPlay) {
                    if launcher.progress.isActive {
                        ProgressView().tint(.white).frame(width: 60)
                    } else {
                        Text(auth.isLoggedIn ? "▶ 실행" : "로그인")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 60)
                    }
                }
                .buttonStyle(FlameButtonStyle(height: 38, radius: 8))
                .fixedSize()
                .disabled(!canPlay)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(FlameColor.bgSurface)
        // ⚠️ 예전에는 위쪽 모서리가 둥근 테두리(UnevenRoundedRectangle)를 둘렀다.
        //    화면 폭을 꽉 채우는 바에 둥근 모서리를 주면 양 끝에 배경이 비쳐 떠 보인다.
        //    경계는 얇은 선 하나면 충분하다.
        .overlay(alignment: .top) {
            Rectangle().frame(height: 1).foregroundStyle(FlameColor.bgBorder)
        }
    }

    private var selectedInstance: InstanceMeta? {
        InstanceStore.shared.instances.first { $0.id == launcher.selectedInstanceId }
    }

    private var title: String {
        tab == .installed
            ? (selectedInstance?.name ?? "인스턴스를 선택하세요")
            : (launcher.selectedVersion?.id ?? "버전을 선택하세요")
    }

    private var subtitle: String {
        tab == .installed
            ? (selectedInstance.map { "MC \($0.mcVersion) · \($0.loaderLabel)" } ?? "")
            : (launcher.selectedVersion?.type ?? "")
    }

    private var canPlay: Bool {
        if launcher.progress.isActive { return false }
        if !auth.isLoggedIn { return true }   // 누르면 로그인으로 유도
        return tab == .installed
            ? selectedInstance != nil
            : launcher.selectedVersion.map { VersionRules.isSupported($0.id) } ?? false
    }
}

// MARK: - 실행 준비 모달

private struct LaunchingDialog: View {
    let meta: InstanceMeta

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().tint(FlameColor.primary)
                    Text("게임을 실행하는 중")
                        .font(.system(size: Sizing.isTablet ? 16 : 14, weight: .bold))
                        .foregroundStyle(FlameColor.textMain)
                }
                Text(meta.name)
                    .font(.system(size: Sizing.isTablet ? 14 : 12, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                    .lineLimit(2)
                Text("마인크래프트를 준비하고 있어요.\n잠시만 기다려 주세요.")
                    .font(.system(size: Sizing.isTablet ? 12 : 10))
                    .foregroundStyle(FlameColor.textSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            // ⚠️ maxWidth 로 두면 **내용이 폭을 정한다.** 서브 문구가 한 줄로 뻗어서
            //    바닐라(이름이 짧다)든 모드팩이든 늘 360 까지 벌어졌다.
            //    고정 폭이라야 어느 인스턴스에서나 같은 크기로 보인다.
            .frame(width: Sizing.isTablet ? 300 : 240, alignment: .leading)
            .flameCard(radius: 16)
        }
    }
}

// MARK: - 왼쪽 메뉴 행

/// ⚠️ 두 종류를 한 눈에 구분해야 한다 — 오른쪽 칸을 바꾸는 항목은 **선택 상태**로,
///    전체 화면을 미는 항목은 **꺾쇠**로 표시한다. 같은 모양이면 눌러봐야 알 수 있다.
private struct SectionRow: View {
    let section: MainSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? .white : FlameColor.primary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(.system(size: 13, weight: selected ? .bold : .semibold))
                        .foregroundStyle(selected ? .white : FlameColor.textMain)
                    Text(section.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(selected ? .white.opacity(0.7) : FlameColor.textSub)
                }
                .lineLimit(1)

                Spacer(minLength: 4)

                if section.showsInDetail {
                    if selected {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.white)
                    }
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlameColor.textSub)
                }
            }
            .padding(.horizontal, 12)
            // ⚠️ 폰 가로에서 항목 6개가 **스크롤 없이** 들어가야 한다. 11pt 였을 때는
            //    한 줄이 51pt 라 6줄이 346pt — 상단바를 뺀 가용 높이(약 320pt)를 넘겨
            //    마지막 두 개("온라인 LAN"·"업데이트 노트")가 화면 밖으로 밀렸다.
            //    스크롤은 되지만, 메뉴가 스크롤될 거라고 기대하는 사람은 없다.
            .padding(.vertical, Sizing.isTablet ? 11 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flameSelectableCard(selected: selected, radius: 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 버전 변경 시트

/// 설치됨 탭의 "선택됨" 카드에서 여는 버전 목록.
///
/// ⚠️ 기존 인스턴스의 MC 버전을 제자리에서 바꾸지 않는다 — 라이브러리·에셋·로더가 전부
///    버전에 묶여 있어 사실상 재설치다. 고른 버전으로 **새 인스턴스를 만든다**(로더 선택으로 이어짐).
private struct VersionPickerSheet: View {
    let versions: [VersionEntry]
    let onPick: (VersionEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var releasesOnly = true

    private var shown: [VersionEntry] {
        releasesOnly ? versions.filter(\.isRelease) : versions
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FlameColor.bgDark.ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("", selection: $releasesOnly) {
                        Text("정식 출시").tag(true)
                        Text("전체").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(shown) { version in
                                VersionRow(version: version, selected: false)
                                    .onTapGesture { onPick(version) }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("버전 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }.foregroundStyle(FlameColor.textSub)
                }
            }
        }
        .modifier(WidePresentation())
    }
}
