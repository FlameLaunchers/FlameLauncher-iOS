import SwiftUI

/// 인게임 설정 메뉴. 안드로이드 `InGameMenuOverlay`(오른쪽 슬라이드 패널) 이식.
///
/// 세 구역:
///  1) GUI(화면 버튼) 표시 토글
///  2) 핫바 터치 영역 크기 (Auto / 1~4)
///  3) 렌더 해상도 (게임 중에 바로 반영된다)
///  4) 게임 종료
///
/// 온라인 LAN(Terracotta)도 여기 있다. 런처 왼쪽 메뉴가 아니라 **인게임 메뉴**에 둔 이유는
/// 쓰는 순간이 게임 안이기 때문이다 — 월드를 열고 `ESC → LAN 에 공개` 를 누른 **다음에**
/// 방을 열어야 하고, 참가할 때 받은 주소는 게임의 서버 목록에 바로 넣어야 한다.
/// 런처 화면에 있으면 그때마다 게임을 빠져나와야 한다.
///
/// ⚠️ TUN 은 쓰지 않는다. iOS 에서 TUN 은 NetworkExtension 뿐이고 그 권한은 무료 개발자
///    계정으로 서명되지 않는다. EasyTier 의 no-TUN 모드로 도므로 방장 노릇은 그대로 되고,
///    참가는 주소를 직접 넣어야 한다.
struct InGameMenuView: View {
    /// 자바 스레드 덤프를 로그에 남긴다. 부팅이나 화면이 멈췄을 때 쓴다.
    let onDumpThreads: () -> Void
    /// 렌더 해상도(%). 게임이 도는 중에 바꿔도 바로 먹는다 —
    /// 프레임버퍼가 다시 잡히고 GLFW 리사이즈가 게임에 전달된다.
    @Binding var resolutionPercent: Int
    let onQuit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dumped = false
    @State private var terracotta = Terracotta.shared

    var body: some View {
        NavigationStack {
            ZStack {
                FlameColor.bgDark.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        multiplayerCard
                        resolutionCard
                        diagnosticsCard
                        quitCard
                    }
                    .padding(Sizing.isCompact ? 12 : 20)
                }
            }
            .navigationTitle(String(localized: "인게임 설정"))
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

    /// 온라인 LAN 진입. 상태를 여기서 한 줄로 보여주고, 자세한 조작은 다음 화면에서 한다.
    private var multiplayerCard: some View {
        NavigationLink {
            TerracottaView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17))
                    .foregroundStyle(FlameColor.primary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("온라인 LAN")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(FlameColor.textMain)
                    Text(multiplayerSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(FlameColor.textSub)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlameColor.textSub)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flameCard(fill: FlameColor.bgSurface, radius: 12)
        }
        .buttonStyle(.plain)
    }

    private var multiplayerSubtitle: String {
        switch terracotta.state {
        case .hostOK(let room):  return String(localized: "방 열림 · \(room)")
        case .guestOK:           return String(localized: "연결됨")
        case .failed(let why):   return why
        case .stopped:           return String(localized: "월드를 LAN 에 공개한 뒤 방을 여세요")
        default:                 return String(localized: "방 코드로 친구와 함께 하기")
        }
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
