import SwiftUI

/// 게임을 띄우기 전에 JIT 를 켜는 화면. PojavLauncher iOS 의 "JIT 대기" 알림에 해당하지만,
/// 그냥 기다리게만 두지 않고 **왜 필요한지와 지금 쓸 수 있는 방법**을 같이 보여준다.
///
/// 자동 경로(TrollStore / AltServer)가 있으면 진입하자마자 시도하고, 어느 쪽이든 켜지는
/// 즉시 자동으로 넘어간다.
struct JITGateView: View {
    @Environment(JITStatus.self) private var jit
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            FlameColor.bgDark.opacity(0.97).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusCard
                    if let failure = jit.failureMessage { failureCard(failure) }
                    diagnosticsCard
                    buttons
                }
                .padding(Sizing.isCompact ? 16 : 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("⚡ JIT 가 필요합니다")
                .font(.system(size: Sizing.isCompact ? 17 : 20, weight: .bold))
                .foregroundStyle(FlameColor.textMain)
            // 왜 필요한지 한 줄로 — 이게 없으면 사용자는 "왜 이 화면이 뜨지"만 남는다.
            Text("iOS 는 앱이 실행 중에 코드를 만들지 못하게 막습니다. 자바는 그 방식으로 도는 언어라, "
                 + "이 제한을 풀지 않으면 마인크래프트가 뜨지 않거나 5 FPS 도 안 나옵니다.")
                .font(.system(size: Sizing.isCompact ? 11 : 13))
                .foregroundStyle(FlameColor.textSub)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if jit.isWorking {
                    ProgressView().tint(FlameColor.primary)
                } else {
                    Text(jit.method == .impossible ? "🚫" : "⏳").font(.system(size: 20))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(jit.method.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(FlameColor.textMain)
                    Text("설치 유형: \(jit.installType)")
                        .font(.system(size: 11))
                        .foregroundStyle(FlameColor.textSub)
                }
                Spacer()
            }
            Text(jit.method.detail)
                .font(.system(size: 12))
                .foregroundStyle(FlameColor.textSub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(radius: 14)
    }

    private func failureCard(_ message: String) -> some View {
        Text("⚠️ \(message)")
            .font(.system(size: 12))
            .foregroundStyle(FlameColor.red)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flameCard(fill: FlameColor.warnBg, stroke: FlameColor.red.opacity(0.4), radius: 12)
    }

    private var diagnosticsCard: some View {
        DisclosureGroup {
            Text(jit.diagnostics)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlameColor.textSub)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            Text("진단 정보")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FlameColor.textMain)
        }
        .tint(FlameColor.primary)
        .padding(14)
        .flameCard(fill: FlameColor.bgItem, radius: 12)
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            if jit.method != .impossible {
                Button {
                    Task { await jit.retry() }
                } label: {
                    Text(jit.method == .altServer ? "AltServer 다시 찾기" : "다시 확인")
                        .font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(FlameButtonStyle(height: 46))
                .disabled(jit.isWorking)
            }

            Button("돌아가기", action: onCancel)
                .font(.system(size: 13))
                .foregroundStyle(FlameColor.textSub)
        }
    }
}
