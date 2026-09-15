import SwiftUI
import UniformTypeIdentifiers

/// 인스턴스별 설정. 안드로이드 `InstanceSettingsScreen` 이식.
/// 섹션: 이름/아이콘 → 렌더러 → 렌더 해상도 → 설치된 모드 관리 → 가져오기 → 삭제.
struct InstanceSettingsView: View {
    let instanceId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(LauncherModel.self) private var launcher

    @State private var meta: InstanceMeta?
    @State private var mods: [ModFile] = []
    @State private var showDeleteConfirm = false
    @State private var showImporter = false
    @State private var toast: String?
    /// 렌더 해상도(%). 전역 JVM 설정과 같은 값이다.
    @State private var resScale = JvmSettingsStore.load().resolutionScalePercent

    /// 이 배율의 HUD 크기를 **이 화면에서 가능한 최대 대비 %** 로 나타낸 값.
    /// (자세한 이유는 JvmSettings.guiScale 주석 참고 — 배율과 비례하지 않는다)
    private var hudPercent: Int {
        let full = JvmSettings.lastFullFramebufferHeight
        let now = JvmSettings.hudRelativeSize(fullHeightPx: full, percent: resScale)
        let best = (JvmSettings.resScaleMin...JvmSettings.resScaleMax)
            .map { JvmSettings.hudRelativeSize(fullHeightPx: full, percent: $0) }
            .max() ?? now
        return Int((now / best * 100).rounded())
    }

    struct ModFile: Identifiable, Hashable {
        let url: URL
        var id: String { url.lastPathComponent }
        var displayName: String {
            url.lastPathComponent.replacingOccurrences(of: ".disabled", with: "")
        }
        var enabled: Bool { !url.lastPathComponent.hasSuffix(".disabled") }
    }

    var body: some View {
        ZStack {
            FlameColor.bgDark.ignoresSafeArea()

            if let meta {
                ScrollView {
                    VStack(spacing: 12) {
                        header(meta)
                        rendererSection(meta)
                        resolutionSection
                        modsSection(meta)
                        importSection(meta)
                        deleteSection
                    }
                    .padding(Sizing.isTablet ? 20 : 12)
                }
            } else {
                ProgressView().tint(FlameColor.primary)
            }
        }
        .navigationTitle("인스턴스 설정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
        .onAppear(perform: reload)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .alert("인스턴스 삭제", isPresented: $showDeleteConfirm) {
            Button("삭제", role: .destructive) {
                launcher.deleteInstance(instanceId)
                dismiss()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 인스턴스의 월드·모드·설정이 모두 지워집니다. 되돌릴 수 없어요.")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12))
                    .foregroundStyle(FlameColor.textMain)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .flameCard(radius: 10)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 섹션

    private func header(_ meta: InstanceMeta) -> some View {
        HStack(spacing: 14) {
            InstanceIcon(meta: meta, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(meta.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                Text("MC \(meta.mcVersion) · \(meta.loaderLabel)")
                    .font(.system(size: 12)).foregroundStyle(FlameColor.textSub)
                Text(folderSizeLabel(meta))
                    .font(.system(size: 11)).foregroundStyle(FlameColor.textSub.opacity(0.7))
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(radius: 12)
    }

    private func rendererSection(_ meta: InstanceMeta) -> some View {
        card(title: "렌더러", note: "이 인스턴스에만 적용됩니다. '전역 기본'이면 설정 화면의 값을 따릅니다.") {
            VStack(spacing: 6) {
                rendererRow(meta, nil, "전역 기본", "런처 기본 렌더러를 따릅니다")
                ForEach(Renderer.allCases) { r in
                    rendererRow(meta, r, "\(r.emoji) \(r.displayName)", r.summary)
                }
            }
        }
    }

    private func rendererRow(_ meta: InstanceMeta, _ renderer: Renderer?,
                             _ title: String, _ desc: String) -> some View {
        let selected = meta.rendererId == renderer?.rawValue
        return Button {
            InstanceStore.shared.updateRendererId(meta.id, rendererId: renderer?.rawValue)
            reload()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .bold))
                        .foregroundStyle(FlameColor.textMain)
                    Text(desc).font(.system(size: 10))
                        .foregroundStyle(FlameColor.textSub)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if selected { Text("✓").foregroundStyle(FlameColor.primary).fontWeight(.bold) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flameSelectableCard(selected: selected)
        }
        .buttonStyle(.plain)
    }

    /// 인스턴스별 해상도는 전역 설정을 그대로 쓴다 — 안드로이드도 같은 슬라이더를
    /// 두 곳에 뒀지만 값은 하나였다. 여기서 바꾸면 JVM 설정에도 그대로 반영된다.
    private var resolutionSection: some View {
        card(title: "🔍 렌더 해상도",
             note: "낮출수록 FPS가 오르고 화면은 약간 흐려집니다. HUD 크기는 배율에 "
                 + "비례하지 않으니(마인크래프트가 가상 화면을 최소 320x240 으로 잡습니다) "
                 + "HUD 수치가 가장 큰 배율을 고르세요.") {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(get: { Double(resScale) }, set: { resScale = Int($0) }),
                    in: Double(JvmSettings.resScaleMin)...Double(JvmSettings.resScaleMax),
                    step: 5
                )
                .tint(FlameColor.primary)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(resScale >= 100 ? "네이티브" : "\(resScale)%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(FlameColor.primary)
                    Text("HUD \(hudPercent)%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(FlameColor.textSub)
                }
                .frame(width: 66, alignment: .trailing)
            }
        }
        // 이 화면은 전역 설정과 같은 값을 만지므로 계산도 같게 한다.
        // 저장 버튼이 없는 화면이라 움직이는 즉시 반영한다.
        .onChange(of: resScale) { _, percent in
            var settings = JvmSettingsStore.load()
            settings.resolutionScalePercent = percent
            JvmSettingsStore.save(settings)
        }
    }

    private func modsSection(_ meta: InstanceMeta) -> some View {
        card(title: "설치된 모드 (\(mods.count)개)", note: nil) {
            if mods.isEmpty {
                Text("이 인스턴스에 설치된 모드가 없어요")
                    .font(.system(size: 12)).foregroundStyle(FlameColor.textSub)
            } else {
                VStack(spacing: 6) {
                    ForEach(mods) { mod in
                        HStack(spacing: 8) {
                            Text(mod.enabled ? "🧩" : "💤")
                            Text(mod.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(mod.enabled ? FlameColor.textMain : FlameColor.textSub)
                                .lineLimit(1)
                            Spacer()
                            Button(mod.enabled ? "끄기" : "켜기") { toggleMod(mod) }
                                .font(.system(size: 11))
                                .foregroundStyle(FlameColor.textSub)
                            Button("🗑") { deleteMod(mod) }
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .flameCard(fill: FlameColor.bgItem, radius: 8)
                    }
                }
            }
        }
    }

    private func importSection(_ meta: InstanceMeta) -> some View {
        card(title: "가져오기", note: "모드(.jar) · 리소스팩/맵(.zip) · 모드팩(.mrpack) 을 파일 앱에서 넣을 수 있어요.") {
            Button("📥 파일에서 가져오기") { showImporter = true }
                .buttonStyle(FlameButtonStyle(height: 42))
                .font(.system(size: 13, weight: .bold))
        }
    }

    private var deleteSection: some View {
        Button("이 인스턴스 삭제") { showDeleteConfirm = true }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(FlameColor.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .flameCard(fill: FlameColor.warnBg, stroke: FlameColor.red.opacity(0.4), radius: 12)
            .flameTappable()
    }

    private func card<Content: View>(title: String, note: String?,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: Sizing.isTablet ? 15 : 13, weight: .bold))
                .foregroundStyle(FlameColor.textMain)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
            }
            content()
        }
        .padding(Sizing.pick(16, 12, 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(radius: 12)
    }

    // MARK: - 동작

    private func reload() {
        meta = InstanceStore.shared.loadMeta(id: instanceId)
        guard let meta else { return }
        let modsDir = meta.dir.appending(path: "mods")
        let files = (try? FileManager.default.contentsOfDirectory(at: modsDir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        mods = files
            .filter { $0.lastPathComponent.hasSuffix(".jar") || $0.lastPathComponent.hasSuffix(".disabled") }
            .map(ModFile.init)
            .sorted { $0.displayName < $1.displayName }
    }

    /// 확장자를 `.disabled` 로 바꿔 로더가 못 읽게 한다 — 안드로이드와 같은 방식.
    private func toggleMod(_ mod: ModFile) {
        let target = mod.enabled
            ? mod.url.deletingLastPathComponent().appending(path: mod.url.lastPathComponent + ".disabled")
            : mod.url.deletingLastPathComponent().appending(path: mod.displayName)
        try? FileManager.default.moveItem(at: mod.url, to: target)
        reload()
    }

    private func deleteMod(_ mod: ModFile) {
        try? FileManager.default.removeItem(at: mod.url)
        reload()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let meta, case .success(let urls) = result else { return }
        let installer = ContentInstaller { _ in }
        var messages: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { messages.append(try installer.importLocal(url, into: meta)) }
            catch { messages.append(error.localizedDescription) }
        }
        showToast(messages.joined(separator: "\n"))
        reload()
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }

    private func folderSizeLabel(_ meta: InstanceMeta) -> String {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: meta.dir,
                                                          includingPropertiesForKeys: Array(keys))
        else { return "" }
        var bytes = 0
        for case let url as URL in walker {
            bytes += (try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
