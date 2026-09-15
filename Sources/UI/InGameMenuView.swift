import SwiftUI

/// 인게임 설정 메뉴. 안드로이드 `InGameMenuOverlay`(오른쪽 슬라이드 패널) 이식.
///
/// 세 구역:
///  1) GUI(화면 버튼) 표시 토글
///  2) 핫바 터치 영역 크기 (Auto / 1~4)
///  3) 렌더 해상도 (게임 중에 바로 반영된다)
///  4) 게임 종료
///
/// 안드로이드의 4번째 구역인 온라인 LAN(Terracotta)은 여기 없다 —
/// 안드로이드는 VpnService 로 TUN 장치를 열어 P2P 를 했는데, iOS 에서 같은 일을 하려면
/// NetworkExtension(Personal VPN) 엔타이틀먼트가 필요하고 이는 애플 승인 대상이다.
/// 자세한 내용은 README 의 '옮기지 않은 것' 절.
struct InGameMenuView: View {
    /// 자바 스레드 덤프를 로그에 남긴다. 부팅이나 화면이 멈췄을 때 쓴다.
    let onDumpThreads: () -> Void
    @Binding var hotbarScale: Int
    /// 렌더 해상도(%). 게임이 도는 중에 바꿔도 바로 먹는다 —
    /// 프레임버퍼가 다시 잡히고 GLFW 리사이즈가 게임에 전달된다.
    @Binding var resolutionPercent: Int
    let onQuit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dumped = false

    var body: some View {
        NavigationStack {
            ZStack {
                FlameColor.bgDark.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        hotbarCard
                        resolutionCard
                        diagnosticsCard
                        quitCard
                    }
                    .padding(Sizing.isCompact ? 12 : 20)
                }
            }
            .navigationTitle("인게임 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }.foregroundStyle(FlameColor.textSub)
                }
            }
        }
        .presentationDetents([.medium, .large])
        // ⚠️ 가로 모드에서 iOS 기본 시트는 **폭이 고정된 카드**로 뜬다(양옆이 크게 남는다).
        //    게임 화면은 가로 고정이라 그 모양이 특히 어색해서, 화면 폭에 맞게 편다.
        .modifier(WidePresentation())
    }

    private var hotbarCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("핫바 터치 영역 크기")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(FlameColor.textMain)
            // 화면 핫바 크기는 마인크래프트 옵션(GUI Scale)에서 바꾸고,
            // 여기서는 "핫바를 터치로 인식하는 영역"만 거기에 맞춘다.
            Text("Auto 가 안 맞으면 1~4 로 직접 맞추세요 (마인크래프트 GUI Scale 과 같은 단위)")
                .font(.system(size: 11)).foregroundStyle(FlameColor.textSub)

            HStack(spacing: 6) {
                ForEach(0...4, id: \.self) { value in
                    let selected = hotbarScale == value
                    Button { hotbarScale = value } label: {
                        Text(value == 0 ? "Auto" : "\(value)")
                            .font(.system(size: 12, weight: selected ? .bold : .regular))
                            .foregroundStyle(selected ? .white : FlameColor.textSub)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .flameCard(fill: selected ? FlameColor.flame : FlameColor.bgSurface,
                                       stroke: selected ? FlameColor.flame : FlameColor.bgBorder,
                                       radius: 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(fill: FlameColor.bgItem, radius: 10)
    }

    private var resolutionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("렌더 해상도")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(FlameColor.textMain)
                Spacer()
                Text(resolutionPercent >= 100 ? "네이티브" : "\(resolutionPercent)%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlameColor.primary)
            }
            Text("낮출수록 프레임버퍼가 작아져 FPS가 오르고 메모리도 덜 씁니다 (화면은 약간 흐려집니다)")
                .font(.system(size: 11)).foregroundStyle(FlameColor.textSub)

            Slider(
                value: Binding(get: { Double(resolutionPercent) },
                               set: { resolutionPercent = Int($0) }),
                in: Double(JvmSettings.resScaleMin)...Double(JvmSettings.resScaleMax),
                step: 5
            )
            .tint(FlameColor.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(fill: FlameColor.bgItem, radius: 10)
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("진단").font(.system(size: 14, weight: .bold))
                .foregroundStyle(FlameColor.textMain)
            Text("게임이 멈춘 것 같을 때 누르세요. 모든 자바 스레드가 지금 무엇을 하고 있는지 로그에 남습니다.")
                .font(.system(size: 11)).foregroundStyle(FlameColor.textSub)

            Button("스레드 덤프 남기기") {
                onDumpThreads()
                dumped = true
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(FlameColor.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .flameCard(fill: FlameColor.bgSurface, stroke: FlameColor.bgBorder, radius: 8)
            .flameTappable()

            if dumped {
                Text("✅ latestlog.txt 에 남겼습니다")
                    .font(.system(size: 11)).foregroundStyle(FlameColor.primary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(fill: FlameColor.bgItem, radius: 10)
    }

    private var quitCard: some View {
        // ⚠️ 여기서 dismiss() 를 부르면 안 된다. 시트를 닫는 것과 부모(fullScreenCover)를
        //    내리는 것이 같은 프레임에 겹치면 SwiftUI 가 둘 중 하나를 삼켜서
        //    "게임 종료를 눌러도 런처로 안 돌아가는" 증상이 난다. 정리는 부모가 한다.
        Button("게임 종료") { onQuit() }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(FlameColor.red)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .flameCard(fill: FlameColor.warnBg, stroke: FlameColor.red.opacity(0.4), radius: 10)
        .flameTappable()
    }
}


/// 가로 모드에서 시트가 화면 폭을 쓰도록 한다. (iOS 18+ 에서만 조절 가능)
/// ⚠️ 가로 모드에서 iOS 기본 시트는 **폭이 고정된 카드**로 떠서 양옆이 크게 남는다.
/// 인게임 메뉴와 버전 선택 시트가 같은 문제를 겪으므로 한 곳에 둔다.
struct WidePresentation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}
