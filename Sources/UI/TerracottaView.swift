import SwiftUI

/// 온라인 LAN(테라코타). 안드로이드 `TerracottaScreen` 이식.
///
/// 방장은 LAN 월드를 열어 두면 방 코드가 나오고, 게스트는 그 코드로 붙는다.
///
/// ⚠️ iOS 에는 TUN 이 없다(Network Extension 권한이 무료 계정으로 서명되지 않는다).
///    EasyTier 의 no-TUN 모드는 **"접근받을 수는 있지만 먼저 걸 수는 없다"** 가 문서화된
///    제약이라, 방장 쪽은 그대로 되고 게스트 쪽은 주소를 직접 넣어 접속해야 한다.
///    그 사정을 화면에서 숨기지 않고 그대로 적는다 — 안 되는 걸 되는 척하면 더 나쁘다.
struct TerracottaView: View {
    @Environment(AuthStore.self) private var auth
    @State private var terracotta = Terracotta.shared
    @State private var roomInput = ""
    @FocusState private var roomFocused: Bool

    private var playerName: String? { auth.username }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard

                if let failure = terracotta.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(FlameColor.primary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .flameCard(fill: FlameColor.bgDark, radius: 10)
                }

                switch terracotta.state {
                case .hostOK(let room):  hostPanel(room: room)
                case .guestOK(let url):  guestPanel(url: url)
                default:                 actionPanel
                }

                limitationNote
            }
            .padding(Sizing.isTablet ? 20 : 14)
        }
        .background(FlameColor.bgDark)
        .navigationTitle(String(localized: "온라인 LAN"))
        .navigationBarTitleDisplayMode(.inline)
        .task { terracotta.start() }
        .onDisappear { terracotta.pausePolling() }
    }

    // MARK: - 상태

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 18))
                .foregroundStyle(statusTint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                Text(statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(FlameColor.textSub)
            }
            Spacer(minLength: 8)
            if terracotta.state.isBusy {
                ProgressView().tint(FlameColor.primary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(fill: FlameColor.bgSurface, radius: 12)
    }

    private var statusIcon: String {
        switch terracotta.state {
        case .stopped:                    return "moon.zzz.fill"
        case .waiting:                    return "dot.radiowaves.left.and.right"
        case .hostScanning, .hostStarting: return "magnifyingglass"
        case .hostOK:                     return "antenna.radiowaves.left.and.right"
        case .guestConnecting, .guestStarting: return "arrow.triangle.2.circlepath"
        case .guestOK:                    return "checkmark.circle.fill"
        case .failed:                     return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch terracotta.state {
        case .hostOK, .guestOK: return .green
        case .failed:           return FlameColor.primary
        default:                return FlameColor.textSub
        }
    }

    private var statusTitle: String {
        switch terracotta.state {
        case .stopped:          return String(localized: "꺼져 있음")
        case .waiting:          return String(localized: "대기 중")
        case .hostScanning:     return String(localized: "LAN 월드를 찾는 중")
        case .hostStarting:     return String(localized: "방을 여는 중")
        case .hostOK:           return String(localized: "방이 열렸습니다")
        case .guestConnecting:  return String(localized: "방에 연결하는 중")
        case .guestStarting:    return String(localized: "접속을 준비하는 중")
        case .guestOK:          return String(localized: "연결됐습니다")
        case .failed(let why):  return why
        }
    }

    private var statusDetail: String {
        switch terracotta.state {
        case .stopped:      return String(localized: "잠시 후 자동으로 시작합니다")
        case .waiting:      return String(localized: "방을 열거나 방 코드로 참가하세요")
        case .hostScanning: return String(localized: "게임에서 월드를 열고 'LAN 에 공개'를 눌러주세요")
        case .hostOK:       return String(localized: "친구에게 아래 코드를 알려주세요")
        case .guestOK:      return String(localized: "게임의 서버 목록에서 아래 주소로 접속하세요")
        case .failed:       return String(localized: "다시 시도하거나 방 코드를 확인해주세요")
        default:            return String(localized: "잠시만 기다려주세요")
        }
    }

    // MARK: - 방장 / 게스트

    private func hostPanel(room: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("방 코드").font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
            HStack(spacing: 10) {
                Text(room)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlameColor.textMain)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = room
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlameColor.primary)
            }
            Button("방 닫기") { Task { await terracotta.reset() } }
                .buttonStyle(FlameButtonStyle(height: 42, radius: 10))
                .font(.system(size: 14, weight: .bold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(fill: FlameColor.bgSurface, radius: 12)
    }

    private func guestPanel(url: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("접속 주소").font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
            HStack(spacing: 10) {
                Text(url ?? "주소를 받는 중…")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlameColor.textMain)
                    .textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                if let url {
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        Label("복사", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(FlameColor.primary)
                }
            }
            Button("연결 끊기") { Task { await terracotta.reset() } }
                .buttonStyle(FlameButtonStyle(height: 42, radius: 10))
                .font(.system(size: 14, weight: .bold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(fill: FlameColor.bgSurface, radius: 12)
    }

    // MARK: - 조작

    @ViewBuilder
    private var actionPanel: some View {
        let disabled = terracotta.port == 0 || terracotta.state.isBusy

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("방 열기").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                Text("게임에서 월드를 연 뒤 'LAN 에 공개'를 누르고, 아래 버튼을 눌러주세요.")
                    .font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
                Button("방 열기") { Task { await terracotta.host(player: playerName) } }
                    .buttonStyle(FlameButtonStyle(height: 44, radius: 10))
                    .font(.system(size: 14, weight: .bold))
                    .disabled(disabled)
            }

            Divider().overlay(FlameColor.bgBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text("방 참가").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                TextField(String(localized: "방 코드"), text: $roomInput)
                    .focused($roomFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(FlameColor.textMain)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .flameCard(fill: FlameColor.bgDark, radius: 10)
                    .submitLabel(.join)
                    .onSubmit(join)
                Button("참가") { join() }
                    .buttonStyle(FlameButtonStyle(height: 44, radius: 10))
                    .font(.system(size: 14, weight: .bold))
                    .disabled(disabled || roomInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(fill: FlameColor.bgSurface, radius: 12)
    }

    private func join() {
        let room = roomInput.trimmingCharacters(in: .whitespaces)
        guard !room.isEmpty else { return }
        roomFocused = false
        Task { await terracotta.join(room: room, player: playerName) }
    }

    // MARK: - 한계 안내

    private var limitationNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("iOS 에서의 제약", systemImage: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlameColor.textMain)
            Text("""
                iOS 는 앱이 가상 네트워크 장치를 만드는 것을 허용하지 않습니다. \
                그래서 **방을 여는 쪽은 그대로 동작**하지만, 참가할 때는 서버 목록에 \
                자동으로 뜨지 않고 위에 나온 주소를 직접 입력해야 합니다.
                """)
                .font(.system(size: 11))
                .foregroundStyle(FlameColor.textSub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(fill: FlameColor.bgDark, radius: 10)
    }
}
