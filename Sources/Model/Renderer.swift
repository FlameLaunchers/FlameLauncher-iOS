import Foundation

/// 렌더러(GL 백엔드).
///
/// dylib 이름은 네이티브 브릿지(`flame_environ.h` 의 RENDERER_NAME_*)와 **반드시 같아야 한다**.
///
/// MetalANGLE(`libtinygl4angle.dylib`)은 뺐다 — gl* 를 51 개만 내보내는 얇은 shim 이라
/// MobileGlues(2700 개 이상)와 겹치면서 더 좁기만 하다. 고를 이유가 없는 선택지였다.
enum Renderer: String, CaseIterable, Identifiable, Codable {
    /// MobileGlues — 데스크톱 GL 을 GLES 로 구현한다. 그 GLES 는 ANGLE 이 Metal 로 받는다. 기본값.
    case mobileglues
    /// GL4ES — 데스크톱 GL → GLES2. 구버전(1.12 이하)용.
    case gl4es
    /// Zink — OSMesa 의 Gallium zink 드라이버가 GL 을 Vulkan(MoltenVK)으로 번역한다.
    case zink

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mobileglues: return "MobileGlues"
        case .gl4es: return "GL4ES"
        case .zink:  return "Zink (MoltenVK)"
        }
    }

    var emoji: String {
        switch self {
        case .mobileglues: return "🧊"
        case .gl4es: return "🕹️"
        case .zink:  return "🌋"
        }
    }

    var summary: String {
        switch self {
        case .mobileglues:
            return "기본값. GL 구현이 가장 넓고 Zink보다 훨씬 가벼움. 셰이더가 되는 유일한 선택지. 1.17+ 권장."
        case .gl4es:
            return "OpenGL을 GLES2로 번역. 구버전(1.12 이하) 부팅용 — pre-1.13 은 자동으로 이걸 쓴다."
        case .zink:
            return "OpenGL을 Vulkan(MoltenVK)으로 번역. 더 무겁고, 셰이더는 Metal 에 transform feedback 이 없어 로딩되지 않는다."
        }
    }

    /// 네이티브가 dlopen 할 dylib 이름. `Frameworks/` 안에 이 이름으로 있어야 한다.
    var libName: String {
        switch self {
        case .mobileglues: return "libmobileglues.dylib"
        case .gl4es: return "libgl4es_114.dylib"
        case .zink:  return "libOSMesa.8.dylib"
        }
    }

    /// OSMesa 경로는 프레임버퍼를 CGImage 로 올리므로 CAMetalLayer 가 아니라 일반 CALayer 를 쓴다.
    var usesMetalLayer: Bool { self != .zink }

    /// JVM 부팅 전에 세팅할 환경변수.
    /// ⚠️ 키 이름은 PojavLauncher 계열 네이티브가 그대로 읽으므로 바꾸면 안 된다.
    var environment: [String: String] {
        var env = ["POJAV_RENDERER": libName]
        switch self {
        case .mobileglues:
            // 설정은 전부 MG_DIR_PATH/config.json 에서 읽는다(GameLauncher 가 넘긴다).
            break
        case .gl4es:
            env["LIBGL_ES"] = "2"
            env["LIBGL_GL"] = "21"          // 데스크톱 GL 2.1 에뮬레이션 (구버전 호환)
            env["LIBGL_MIPMAP"] = "3"
            env["LIBGL_NORMALIZE"] = "1"
            env["LIBGL_NOERROR"] = "1"
            env["LIBGL_USEVBO"] = "1"       // pre-1.13 의 VBO 미사용 랜덤 크래시 회피
            env["LIBGL_SHADERCONVERTER"] = "1"
            env["LIBGL_FB"] = "2"
        case .zink:
            env["GALLIUM_DRIVER"] = "zink"
            env["MESA_LOADER_DRIVER_OVERRIDE"] = "zink"
            env["MESA_GL_VERSION_OVERRIDE"] = "4.1"
            env["force_glsl_extensions_warn"] = "true"
            env["allow_higher_compat_version"] = "true"
            env["allow_glsl_extension_directive_midshader"] = "true"
        }
        return env
    }
}

enum RendererStore {
    private static let file = JSONFile<String>(name: "renderer.json", fallback: Renderer.mobileglues.rawValue)

    static func load() -> Renderer { Renderer(rawValue: file.load()) ?? .mobileglues }
    static func save(_ r: Renderer) { file.save(r.rawValue) }

    /// 인스턴스 설정 → 전역 기본 → pre-1.13 이면 GL4ES 강제, 순서로 해석한다.
    /// 안드로이드 `MinecraftActivity.resolveRendererForVersion` 과 같은 규칙.
    static func resolve(for meta: InstanceMeta) -> Renderer {
        let picked = meta.rendererId.flatMap(Renderer.init(rawValue:)) ?? load()
        if VersionRules.isPre113(meta.mcVersion) && picked != .gl4es { return .gl4es }
        return picked
    }
}
