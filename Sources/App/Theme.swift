import SwiftUI

/// Android `presentation/ui/theme/Color.kt` 를 그대로 옮긴 팔레트.
/// 값(0xAARRGGBB)은 안드로이드와 1:1로 맞춘다 — 두 플랫폼의 화면이 같은 색으로 보여야 한다.
enum FlameColor {
    // ── 푸른 불꽃 팔레트 ──────────────────────────────────────────────────
    // 불꽃은 뜨거울수록 푸르다 — 심지 쪽이 시안, 바깥이 짙은 청색이다.
    // 그 온도 그라데이션을 그대로 역할에 대응시킨다:
    //   accent(가장 뜨거움) → primary → light → dark(바깥 불꽃)
    // 배경은 검정이 아니라 **푸른기 도는 검정**이라 불꽃색이 겉돌지 않는다.
    static let orange       = hex(0x5AB8FF)   // (이름은 유지) 중간 톤 블루
    static let bgDim        = hex(0x05080F, alpha: 0.6)
    static let flame        = hex(0x2E9BFF)   // 포인트 컬러 (블루 플레임)
    static let bgDark       = hex(0x05080F)   // 가장 어두운 배경 (푸른 검정)
    static let bgSurface    = hex(0x0B1422)   // 카드 / 서피스 배경
    static let bgBorder     = hex(0x1C2E47)   // 테두리
    static let bgItem       = hex(0x08101B)   // 리스트 아이템
    static let textMain     = hex(0xE8F2FF)   // 기본 텍스트 (쿨 화이트)
    static let textSub      = hex(0x8CA2C0)   // 보조 텍스트 (쿨 그레이)
    static let green        = hex(0x3DD68C)   // 성공
    static let red          = hex(0xFF5F7E)   // 오류 (푸른 배경에서 잘 보이는 톤)
    static let warnBg       = hex(0x2A1424)   // 경고 배경

    static let primary      = hex(0x2E9BFF)   // 메인 플레임 (핫 블루)
    static let light        = hex(0x7CC9FF)   // 라이트 플레임
    static let dark         = hex(0x0B4A8F)   // 다크 플레임 (딥 블루)
    static let accent       = hex(0x22E0FF)   // 액센트 (시안 — 불꽃 심지)

    static let tagRelease   = hex(0x7CC9FF)
    static let tagSnapshot  = hex(0xA78BFA)   // 스냅샷 (바이올렛)
    static let tagOld       = hex(0x6D7F96)

    static func hex(_ rgb: UInt32, alpha: Double = 1) -> Color {
        Color(
            .sRGB,
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue:  Double(rgb & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - 반응형 크기

/// Compose 쪽 `WindowSizeUtil` 대응. 안드로이드는 smallestScreenWidthDp 로 갈랐지만
/// iOS 에는 폴더블이 없으므로 idiom + 가로폭으로 충분하다.
enum Sizing {
    static var isTablet: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// iPhone SE / mini 처럼 좁은 화면. Compose 의 `isCompact()`(sw < 360dp) 대응.
    static var isCompact: Bool {
        !isTablet && UIScreen.main.bounds.width < 380
    }

    /// tablet / compact / 일반 폰 세 갈래로 값을 고르는 헬퍼.
    /// Compose 코드가 `if (tablet) 14.sp else if (compact) 10.sp else 12.sp` 를
    /// 도배하고 있어서, 그 패턴을 한 줄로 줄인다.
    static func pick<T>(_ tablet: T, _ phone: T, _ compact: T) -> T {
        if isTablet { return tablet }
        return isCompact ? compact : phone
    }
}

// MARK: - 공통 스타일

/// Compose 의 `background(BgSurface) + border(1.dp, BgBorder, RoundedCornerShape(r))` 조합.
/// 이 조합이 안드로이드 UI 전반에서 카드/버튼/입력창까지 전부를 만들고 있어서 하나로 뽑았다.
struct FlameCard: ViewModifier {
    var fill: Color = FlameColor.bgSurface
    var stroke: Color = FlameColor.bgBorder
    var radius: CGFloat = 12
    var lineWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(stroke, lineWidth: lineWidth)
            )
    }
}

extension View {
    /// 버튼 **바깥**에 붙인 여백·카드까지 눌리게 한다.
    ///
    /// ⚠️ SwiftUI 의 Button 은 **라벨 모양**으로만 히트 테스트한다. `.padding()` 이나
    ///    `.flameCard()` 를 버튼 바깥에 걸면 보이는 넓이만 커지고 탭 영역은 글자 그대로 남는다.
    ///    실제로 "이 인스턴스 삭제" 카드는 글자 양옆을 눌러도 아무 일도 일어나지 않았다.
    ///    카드처럼 보이는 것은 카드 전체가 눌려야 한다.
    func flameTappable() -> some View { contentShape(Rectangle()) }

    func flameCard(
        fill: Color = FlameColor.bgSurface,
        stroke: Color = FlameColor.bgBorder,
        radius: CGFloat = 12,
        lineWidth: CGFloat = 1
    ) -> some View {
        modifier(FlameCard(fill: fill, stroke: stroke, radius: radius, lineWidth: lineWidth))
    }

    /// 선택 상태에 따라 채움/테두리를 바꾸는 카드(목록 항목·탭 전용).
    func flameSelectableCard(selected: Bool, radius: CGFloat = 10) -> some View {
        flameCard(
            fill: selected ? FlameColor.dark : FlameColor.bgSurface,
            stroke: selected ? FlameColor.primary : FlameColor.bgBorder,
            radius: radius,
            lineWidth: selected ? 1.5 : 1
        )
    }
}

/// 주황 채움 + 흰 글씨 + 비활성 시 테두리색 — 안드로이드의 Play/저장 버튼 스타일.
struct FlameButtonStyle: ButtonStyle {
    var height: CGFloat = 48
    var radius: CGFloat = 10
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(.white)
            .background(
                isEnabled ? FlameColor.primary : FlameColor.bgBorder,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
