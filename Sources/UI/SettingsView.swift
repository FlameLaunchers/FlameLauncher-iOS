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
                valueLabel: "\(settings.resolutionScalePercent)%",
                note: "낮출수록 프레임버퍼가 작아져 FPS가 오르고 화면은 약간 흐려집니다."
            )
        }
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
