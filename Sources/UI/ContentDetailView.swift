import SwiftUI

/// 콘텐츠 상세 + 설치. 안드로이드 `ContentPackDetailScreen` 이식.
struct ContentDetailView: View {
    let item: ContentItem

    @Environment(LauncherModel.self) private var launcher
    @Environment(\.dismiss) private var dismiss

    @State private var description: String?
    @State private var files: [ContentFile] = []
    @State private var isLoading = true
    @State private var progress = DownloadProgress()
    @State private var targetInstanceId: String?
    @State private var result: String?
    /// 대상 인스턴스에 맞지 않는 빌드까지 보여줄지. 기본은 끔.
    @State private var showAllVersions = false

    private var instances: [InstanceMeta] { InstanceStore.shared.instances }
    /// 설치 대상. 목록을 어느 버전으로 거를지도 이걸로 정한다.
    private var target: InstanceMeta? {
        targetInstanceId.flatMap { InstanceStore.shared.loadMeta(id: $0) }
    }
    /// 모드팩이면 새 인스턴스를 만들고, 나머지는 기존 인스턴스에 넣는다.
    ///
    /// ⚠️ 파일 확장자로 가리면 안 된다 — 셰이더·리소스팩·맵도 전부 `.zip` 이라
    ///    모드팩으로 오인돼 "modrinth.index.json / manifest.json" 오류로 설치가 막혔다.
    private var isPack: Bool { item.type == .modpack }

    var body: some View {
        ZStack {
            FlameColor.bgDark.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if progress.isActive {
                        ProgressRow(progress: progress).padding(.vertical, 4)
                    }

                    if !isPack && !instances.isEmpty { targetPicker }

                    filesSection

                    if let description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("설명").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(FlameColor.textMain)
                            // 서버가 주는 건 마크다운(Modrinth) 또는 HTML(CurseForge)이다.
                            // 안드로이드는 WebView 로 띄웠지만, 여기서는 태그를 걷어내고
                            // 본문만 보여준다 — 상세 화면에서 필요한 건 결국 글이다.
                            Text(Self.plainText(description))
                                .font(.system(size: 12))
                                .foregroundStyle(FlameColor.textSub)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .flameCard(radius: 12)
                    }
                }
                .padding(14)
            }

            if isLoading { ProgressView().tint(FlameColor.primary) }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
        .task { await load() }
        .onChange(of: targetInstanceId) { _, _ in Task { await reloadFiles() } }
        .onChange(of: showAllVersions) { _, _ in Task { await reloadFiles() } }
        .alert("설치", isPresented: .constant(result != nil)) {
            Button("확인") { result = nil }
        } message: {
            Text(result ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AsyncImage(url: item.logoURL) { $0.resizable().scaledToFill() } placeholder: {
                Image("anvil").resizable().scaledToFit().padding(10)
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: 17, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                Text("\(item.source.label) · ⬇ \(item.downloadsLabel)")
                    .font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
                Text(item.summary).font(.system(size: 12))
                    .foregroundStyle(FlameColor.textSub).lineLimit(3)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(radius: 12)
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("설치할 인스턴스").font(.system(size: 13, weight: .bold))
                .foregroundStyle(FlameColor.textMain)
            Picker("인스턴스", selection: $targetInstanceId) {
                ForEach(instances) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
            .tint(FlameColor.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(radius: 12)
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("버전 (\(files.count))").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                Spacer()
                if !isPack, let target {
                    Toggle(isOn: $showAllVersions) {
                        Text("모든 버전")
                            .font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
                    }
                    .toggleStyle(.switch)
                    .tint(FlameColor.primary)
                    .fixedSize()
                    .help("\(target.mcVersion) 이외의 빌드도 보여줍니다")
                }
            }

            if !isPack, !showAllVersions, let target {
                Text("\(target.mcVersion)\(target.loaderType.map { " · " + $0 } ?? "") 에 맞는 빌드만 보여줍니다")
                    .font(.system(size: 10)).foregroundStyle(FlameColor.textSub)
            }

            if files.isEmpty && !isLoading {
                Text(showAllVersions || isPack
                     ? "설치 가능한 파일이 없어요"
                     : "이 인스턴스에 맞는 빌드가 없어요 — '모든 버전' 을 켜면 전부 보입니다")
                    .font(.system(size: 12)).foregroundStyle(FlameColor.textSub)
            }

            ForEach(files.prefix(20)) { file in
                Button { Task { await install(file) } } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(FlameColor.textMain)
                                .lineLimit(1)
                            Text(file.gameVersions.prefix(4).joined(separator: ", "))
                                .font(.system(size: 10)).foregroundStyle(FlameColor.textSub)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(isPack ? "설치" : "＋")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(FlameColor.primary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .flameCard(fill: FlameColor.bgItem, radius: 10)
                }
                .buttonStyle(.plain)
                .disabled(progress.isActive)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(radius: 12)
    }

    /// 대상 인스턴스에 맞는 빌드만 남기는 필터.
    ///
    /// ⚠️ 이게 없으면 목록 맨 위가 **최신 마인크래프트용**이다. 실제로 1.21.1 인스턴스에
    ///    Iris 1.11.3+mc26.1.2 가 깔려서 Fabric 이 "Mod resolution failed" 로 거부했다.
    ///    로더는 **모드에만** 건다 — 리소스팩/셰이더의 loaders 는 minecraft·iris 라서
    ///    fabric 으로 거르면 결과가 통째로 사라진다.
    private var versionFilter: (gameVersion: String?, loader: String?) {
        guard !isPack, !showAllVersions, let target else { return (nil, nil) }
        return (target.mcVersion, item.type == .mod ? target.loaderType : nil)
    }

    private func load() async {
        isLoading = true
        // 대상이 정해져야 목록을 거를 수 있다 — 조회 전에 고른다.
        targetInstanceId = targetInstanceId ?? instances.first?.id
        let filter = versionFilter
        async let desc = ContentAPI.description(item)
        async let list = ContentAPI.files(item, gameVersion: filter.gameVersion,
                                          loader: filter.loader)
        (description, files) = await (desc, list)
        isLoading = false
    }

    private func reloadFiles() async {
        isLoading = true
        let filter = versionFilter
        files = await ContentAPI.files(item, gameVersion: filter.gameVersion,
                                       loader: filter.loader)
        isLoading = false
    }

    private func install(_ file: ContentFile) async {
        // ⚠️ 전역(launcher.progress)에도 같이 올린다. 예전에는 이 화면의 @State 에만
        //    담았는데, 설치 중에 목록으로 돌아가거나 화면을 닫으면 **진척도가 통째로
        //    사라졌다.** 모드 로더 설치는 몇 분씩 걸려서 그동안 멈춘 것과 구분이 안 된다.
        let installer = ContentInstaller { p in
            Task { @MainActor in
                progress = p
                launcher.progress = p
            }
        }
        do {
            if isPack {
                let meta = try await installer.installModpack(
                    item, file: file, versions: launcher.versions
                )
                result = "\(meta.name) 설치 완료 — 설치됨 탭에서 실행하세요."
            } else if let target {
                try await installer.installFile(file, type: item.type, source: item.source, into: target)
                var message = "\(target.name) 에 \(file.fileName) 을(를) 넣었습니다."
                if item.type == .shader,
                   let note = ContentInstaller.shaderPrerequisiteNote(for: target) {
                    message += "\n\n⚠️ " + note
                }
                result = message
            } else {
                result = "먼저 인스턴스를 하나 만들어 주세요."
            }
        } catch {
            progress = DownloadProgress(phase: .error, error: error.localizedDescription)
            launcher.progress = progress
            result = error.localizedDescription
        }
    }

    /// HTML/마크다운에서 태그와 링크 문법만 걷어낸다.
    static func plainText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1",
                                  options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
