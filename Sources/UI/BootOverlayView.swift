import SwiftUI

/// 마인크래프트 부팅 중 표시되는 풀스크린 로딩 오버레이.
/// 안드로이드 `MinecraftBootOverlay` 이식 — 게임 표면 위에 얹혀 첫 프레임까지 화면을 가린다.
struct BootOverlayView: View {
    let modCount: Int
    let error: String?
    let onClose: () -> Void

    /// 모드팩이면 첫 실행이 오래 걸린다 — 모드 수로 대기 시간을 안내한다.
    private var maxDelayMinutes: Int { max(1, modCount / 25) }

    var body: some View {
        ZStack {
            FlameColor.bgDark.opacity(0.96).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                if let error {
                    Text("⚠️ 게임을 시작할 수 없어요")
                        .font(.system(size: Sizing.isCompact ? 13 : 16, weight: .bold))
                        .foregroundStyle(FlameColor.textMain)
                    ScrollView {
                        Text(error)
                            .font(.system(size: Sizing.isCompact ? 10 : 12))
                            .foregroundStyle(FlameColor.textSub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    Button("돌아가기", action: onClose)
                        .buttonStyle(FlameButtonStyle(height: 44))
                        .font(.system(size: 14, weight: .bold))
                } else {
                    HStack(spacing: Sizing.isCompact ? 10 : 18) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(FlameColor.flame)
                        VStack(alignment: .leading, spacing: Sizing.isCompact ? 4 : 6) {
                            Text("마인크래프트를 시작하는 중")
                                .font(.system(size: Sizing.isCompact ? 12 : 16, weight: .bold))
                                .foregroundStyle(FlameColor.textMain)
                            Text(modCount > 0
                                 ? String(localized: "모드 \(modCount)개를 불러오는 중이에요. 첫 실행은 최대 \(maxDelayMinutes)분 정도 걸릴 수 있어요.")
                                 : String(localized: "잠시만 기다려 주세요."))
                                .font(.system(size: Sizing.isCompact ? 9 : 12))
                                .foregroundStyle(FlameColor.textSub)
                        }
                    }
                    Button("취소하고 나가기", action: onClose)
                        .font(.system(size: 12))
                        .foregroundStyle(FlameColor.textSub)
                }
            }
            .padding(.horizontal, Sizing.isCompact ? 14 : 24)
            .padding(.vertical, Sizing.isCompact ? 14 : 22)
            .frame(maxWidth: 420)
            .flameCard(radius: 18)
            .padding(20)
        }
    }
}
