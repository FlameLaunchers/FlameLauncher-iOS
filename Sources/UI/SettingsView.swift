import SwiftUI

/// JVM/게임플레이 설정 화면. 안드로이드 `SettingsScreen` 이식.
/// 섹션 구성(렌더러 → 화면 → 메모리 → 게임플레이 → 고급)과 문구를 그대로 유지했다.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings = JvmSettingsStore.load()
    @State private var renderer = RendererStore.load()
    @State private var saved = false

    private let ceiling = JvmSettingsStore.maxHeapCeilingMb

    var body: some View {
        ZStack {
            FlameColor.bgDark.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Sizing.isTablet ? 16 : 10) {
                    if saved {
                        Text("✅ 설정을 저장했어요")
                            .font(.system(size: Sizing.isTablet ? 13 : 11))
                            .foregroundStyle(FlameColor.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(FlameColor.primary.opacity(0.1))
                    }

                    rendererSection
                    screenSection
                    memorySection
                    gameplaySection
                    advancedSection
                }
                .padding(Sizing.isTablet ? 20 : 12)
            }
        }
        .navigationTitle("JVM 설정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("초기화") {
                    settings = JvmSettingsStore.reset()
                    flashSaved()
                }
                .foregroundStyle(FlameColor.red)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("저장") {
                    JvmSettingsStore.save(settings)
                    RendererStore.save(renderer)
                    flashSaved()
                }
                .fontWeight(.bold)
                .foregroundStyle(FlameColor.primary)
            }
        }
    }

    // MARK: - 섹션

    private var rendererSection: some View {
        Section("기본 렌더러", note: "새 인스턴스가 사용할 렌더러. 인스턴스별로 따로 지정할 수도 있어요.") {
            ForEach(Renderer.allCases) { item in
                Button { renderer = item } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.emoji).font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayName)
                                .font(.system(size: Sizing.isTablet ? 14 : 12, weight: .bold))
                                .foregroundStyle(FlameColor.textMain)
                            Text(item.summary)
                                .font(.system(size: Sizing.isTablet ? 12 : 10))
                                .foregroundStyle(FlameColor.textSub)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        if renderer == item {
                            Text("✓").foregroundStyle(FlameColor.primary).fontWeight(.bold)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .flameSelectableCard(selected: renderer == item)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 지금 배율에서 HUD 가 얼마나 커지는지. 기준은 55%(가장 흔한 기본값)가 아니라
    /// **이 화면에서 가능한 최대**(가상 높이 240)로 잡는다 — "최대의 몇 %" 가 직관적이다.
    private var hudLabel: String {
        let full = JvmSettings.lastFullFramebufferHeight
        let now = JvmSettings.hudRelativeSize(fullHeightPx: full,
                                              percent: settings.resolutionScalePercent)
        let best = (JvmSettings.resScaleMin...JvmSettings.resScaleMax)
            .map { JvmSettings.hudRelativeSize(fullHeightPx: full, percent: $0) }
            .max() ?? now
        return "\(Int((now / best * 100).rounded()))%"
    }

    private var screenSection: some View {
        Section("화면 설정") {
            toggleRow("🖥", "전체 화면", "시스템 바를 숨기고 화면을 꽉 채웁니다",
                      isOn: $settings.fullscreen)

            sliderRow(
                "📐", "렌더 해상도",
                value: Binding(
                    get: { Double(settings.resolutionScalePercent) },
                    set: { settings.resolutionScalePercent = Int($0) }
                ),
                range: Double(JvmSettings.resScaleMin)...Double(JvmSettings.resScaleMax),
                step: 5,
                valueLabel: "\(settings.resolutionScalePercent)% · HUD \(hudLabel)",
                note: "낮출수록 프레임버퍼가 작아져 FPS가 오르고 화면은 약간 흐려집니다.\n"
                    + "HUD 크기는 배율에 비례하지 않습니다 — 마인크래프트가 가상 화면을 "
                    + "최소 320x240 으로 잡아서, 배율을 올렸는데 인벤토리가 작아지는 구간이 "
                    + "있습니다. 위 HUD 배수가 클수록 인벤토리·핫바가 큽니다."
            )

            hudRow
        }
    }

    /// HUD 크기를 해상도와 **따로** 고르게 한다.
    ///
    /// ⚠️ "자동" 은 마인크래프트가 정하는 값이고, 폰 가로 화면에서는 항상 스케일 2 에서
    ///    막힌다(가상 화면 ≥ 320x240 이 하드코딩돼 있다). 그 위 단계들은 그 하한을
    ///    실행 중에 낮춰서 얻는 것이라 게임 설정만으로는 나오지 않는다.
    ///
    /// ⚠️ **잘리는 단계는 아예 못 고르게 한다.** 하한을 낮추면 GUI 가 화면보다 커질 수
    ///    있는데(대형 상자가 222 로 가장 크다), 그건 HUD 가 커진 게 아니라 못 쓰게 된
    ///    것이다. 지금 해상도에서 안 되는 단계에는 필요한 해상도를 같이 적어 준다.
    private var hudRow: some View {
        let fullH = JvmSettings.lastFullFramebufferHeight
        let fbH = fullH * settings.resolutionScalePercent / 100
        let maxScale = JvmSettings.maxHudScale(framebufferHeight: fbH)
        let autoScale = JvmSettings.guiScale(fullHeightPx: fullH,
                                             percent: settings.resolutionScalePercent)
        let chosen = settings.hudScale == 0
            ? autoScale
            : JvmSettings.effectiveHudScale(settings.hudScale, framebufferHeight: fbH)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("🔍").font(.system(size: 18))
                Text("HUD 크기").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                Spacer()
                Text(settings.hudScale == 0 ? "자동 (\(autoScale)배)" : "\(chosen)배")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlameColor.primary)
            }

            HStack(spacing: 6) {
                hudChoice(0, label: "자동", enabled: true)
                ForEach(2...4, id: \.self) { value in
                    hudChoice(value, label: "\(value)배", enabled: value <= maxScale)
                }
            }

            Text(hudNote(maxScale: maxScale, autoScale: autoScale, fullH: fullH))
                .font(.system(size: 10))
                .foregroundStyle(FlameColor.textSub)
        }
        .padding(14)
        .flameCard(fill: FlameColor.bgItem, radius: 10)
    }

    /// 고를 수 없는 단계는 눌리지 않고 흐리게 둔다 — 숨기면 왜 없는지 알 수 없다.
    private func hudChoice(_ value: Int, label: String, enabled: Bool) -> some View {
        let selected = settings.hudScale == value
        return Button { if enabled { settings.hudScale = value } } label: {
            Text(label)
                .font(.system(size: 12, weight: selected ? .bold : .regular))
                .foregroundStyle(!enabled ? FlameColor.textSub.opacity(0.4)
                                 : selected ? .white : FlameColor.textSub)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .flameCard(fill: selected ? FlameColor.flame : FlameColor.bgSurface,
                           stroke: selected ? FlameColor.flame : FlameColor.bgBorder,
                           radius: 8)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func hudNote(maxScale: Int, autoScale: Int, fullH: Int) -> String {
        // 다음 단계를 열려면 해상도를 얼마나 올려야 하는지 알려준다.
        if maxScale < 4,
           let need = JvmSettings.minResolutionPercent(forHudScale: maxScale + 1,
                                                       fullHeightPx: fullH),
           need > settings.resolutionScalePercent {
            return "인벤토리·핫바가 커지고 터치 영역도 같이 커집니다. "
                 + "\(maxScale + 1)배는 대형 상자가 잘려서 잠겨 있습니다 — "
                 + "렌더 해상도를 \(need)% 이상으로 올리면 열립니다."
        }
        return maxScale > autoScale
            ? "인벤토리·핫바가 커지고 터치 영역도 같이 커집니다. 잘리는 단계는 잠겨 있습니다."
            : "지금 해상도에서는 자동값이 이미 최대입니다. 해상도를 올리면 더 큰 단계가 열립니다."
    }
    private var memorySection: some View {
        Section("메모리", note: "기기 전체 \(JvmSettingsStore.totalRamMb)MB · 권장 상한 \(ceiling)MB") {
            sliderRow(
                "🧠", "최대 힙 (-Xmx)",
                value: Binding(get: { Double(settings.maxHeapMb) },
                               set: { settings.maxHeapMb = Int($0) }),
                range: 512...Double(ceiling), step: 128,
                valueLabel: "\(settings.maxHeapMb)MB",
                // iOS 는 앱당 메모리 상한이 물리 메모리보다 훨씬 낮고 넘으면 경고 없이 죽는다.
                note: "너무 높이면 iOS가 앱을 강제 종료합니다. 모드팩이 아니면 2048MB 정도면 충분해요."
            )
            toggleRow("♻️", "G1 GC 사용", "일시 정지가 짧은 GC. 대부분 켜두는 게 좋습니다",
                      isOn: $settings.useG1GC)
        }
    }

    private var gameplaySection: some View {
        Section("게임플레이") {
            sliderRow(
                "🌍", "렌더 거리",
                value: Binding(get: { Double(settings.renderDistance) },
                               set: { settings.renderDistance = Int($0) }),
                range: 2...16, step: 1,
                valueLabel: "\(settings.renderDistance) 청크",
                note: "첫 실행에만 적용됩니다. 이후엔 게임 안에서 바꾼 값이 유지돼요."
            )
            sliderRow(
                "🖱", "마우스 감도",
                value: $settings.mouseSensitivity,
                range: 0.3...4, step: 0.1,
                valueLabel: String(format: "%.1f×", settings.mouseSensitivity),
                note: nil
            )
            toggleRow("🚀", "FPS 제한 해제", "260 FPS 상한 + VSync 끔",
                      isOn: $settings.unlockFps)
            toggleRow("☁️", "구름 끄기", "구름 렌더를 꺼서 프레임을 확보합니다",
                      isOn: $settings.disableClouds)
        }
    }

    private var advancedSection: some View {
        Section("고급", note: "한 줄에 하나씩. 무엇을 하는지 아는 경우에만 사용하세요.") {
            TextEditor(text: $settings.extraJvmArgs)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(FlameColor.textMain)
                .scrollContentBackground(.hidden)
                .frame(height: 100)
                .padding(8)
                .flameCard(fill: FlameColor.bgDark, radius: 8)
        }
    }

    // MARK: - 재사용 행

    /// 안드로이드가 SettingToggleRow / SettingSliderRow / 섹션 Column 을 화면마다 다시
    /// 만들던 걸 여기 세 개로 모았다.
    private struct Section<Content: View>: View {
        let title: String
        var note: String?
        @ViewBuilder let content: Content

        init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.note = note
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: Sizing.isTablet ? 15 : 12, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                if let note {
                    Text(note)
                        .font(.system(size: Sizing.isTablet ? 12 : 10))
                        .foregroundStyle(FlameColor.textSub)
                }
                content
            }
            .padding(Sizing.pick(16, 12, 9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .flameCard(radius: 12)
        }
    }

    private func toggleRow(_ emoji: String, _ title: String, _ subtitle: String,
                           isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(emoji).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(FlameColor.primary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .flameCard(fill: FlameColor.bgItem, radius: 10)
    }

    private func sliderRow(_ emoji: String, _ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double,
                           valueLabel: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(emoji).font(.system(size: 18))
                Text(title).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                Spacer()
                Text(valueLabel)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlameColor.primary)
            }
            Slider(value: value, in: range, step: step).tint(FlameColor.primary)
            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(FlameColor.textSub)
            }
        }
        .padding(14)
        .flameCard(fill: FlameColor.bgItem, radius: 10)
    }

    private func flashSaved() {
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saved = false
        }
    }
}
