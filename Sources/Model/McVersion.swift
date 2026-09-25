import Foundation

// MARK: - version_manifest.json (목록)

struct VersionManifestIndex: Codable {
    let latest: Latest
    let versions: [VersionEntry]

    struct Latest: Codable {
        let release: String
        let snapshot: String
    }
}

struct VersionEntry: Codable, Identifiable, Hashable {
    let id: String
    let type: String   // "release", "snapshot", "old_beta", "old_alpha"
    let url: String
    let releaseTime: String

    /// 목록 배지 색을 고르기 위한 분류. 안드로이드 TagRelease/TagSnapshot/TagOld 와 동일.
    var isRelease: Bool { type == "release" }
    var isSnapshot: Bool { type == "snapshot" }
}

// MARK: - <version>.json (개별 버전)

struct VersionManifest: Codable {
    let id: String
    let mainClass: String
    let downloads: Downloads
    let libraries: [Library]
    let assetIndex: AssetIndex
    /// 1.12 이전 전용. 1.13+ 은 `arguments` 객체를 쓴다.
    let minecraftArguments: String?
    /// Mojang 이 알려주는 필요 JRE. 버전 문자열 추측보다 이게 정확하다.
    /// (1.20.5+ 는 21, 1.17~1.20.4 는 17, 그 이전은 8 — 하지만 새 버전 체계에서는
    ///  문자열만 보고는 알 수 없다)
    let javaVersion: JavaVersionRequirement?

    struct JavaVersionRequirement: Codable { let majorVersion: Int }

    struct Downloads: Codable { let client: DownloadItem }

    struct Library: Codable {
        let name: String
        let downloads: LibraryDownloads?
        let natives: [String: String]?
    }

    struct LibraryDownloads: Codable {
        let artifact: DownloadItem?
        let classifiers: [String: DownloadItem]?
    }

    struct AssetIndex: Codable {
        let id: String
        let sha1: String
        let size: Int64
        let totalSize: Int64
        let url: String
    }
}

struct DownloadItem: Codable {
    let url: String
    let size: Int64?
    let sha1: String?
}

/// 다운로드가 끝난 뒤 실행에 필요한 값들.
struct MCPrepareResult {
    let assetIndexId: String
    let mainClass: String
    let minecraftArguments: String?
}

// MARK: - 진행률

enum DownloadPhase: Equatable {
    case idle
    case fetchingManifest
    case downloadingClient
    case downloadingLibraries
    case downloadingAssets
    case installingLoader
    case done
    case error
}

struct DownloadProgress: Equatable {
    var phase: DownloadPhase = .idle
    var current: Int = 0
    var total: Int = 0
    var fileName: String = ""
    var error: String?

    var fraction: Double { total > 0 ? Double(current) / Double(total) : 0 }
    var percent: Int { Int(fraction * 100) }

    var isActive: Bool { phase != .idle && phase != .done && phase != .error }

    /// 안드로이드 SidePlayPanel/MobileBottomBar 의 문구를 그대로 옮긴 것.
    var label: String {
        switch phase {
        case .fetchingManifest:     return String(localized: "버전 정보 가져오는 중...")
        case .downloadingClient:    return String(localized: "클라이언트 내려받는 중...")
        case .downloadingLibraries: return String(localized: "라이브러리 \(current)/\(total)")
        case .downloadingAssets:    return String(localized: "에셋 \(current)/\(total)")
        case .installingLoader:     return String(localized: "모드 로더 설치 중... \(fileName)")
        case .error:                return "❌ " + (error ?? String(localized: "오류"))
        default:                    return ""
        }
    }
}

// MARK: - 버전 판정 (안드로이드 JVMSettings.kt / VersionUtil.kt 이식)

enum VersionRules {
    /// 1.12.2 이하 = legacy(AWT 필요). 베타/알파/클래식 표기도 legacy 로 잡는다.
    /// ⚠️ 안드로이드에서 `removePrefix("1.")` 파서가 b1.7.3 을 modern 으로 오판해
    ///    실행 즉시 크래시하던 버그가 있었다 — 접두사 검사를 먼저 한다.
    static func isLegacy(_ versionId: String) -> Bool {
        let id = versionId.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["b1.", "a1.", "a0.", "c0.", "inf-", "rd-"] where id.hasPrefix(prefix) {
            return true
        }
        guard let major = majorOf(id) else { return false }
        return major <= 12
    }

    static func isPre113(_ versionId: String) -> Bool { isLegacy(versionId) }

    static func isPre117(_ versionId: String) -> Bool {
        if isLegacy(versionId) { return true }
        guard let major = majorOf(versionId) else { return false }
        return major <= 16
    }

    /// 필요한 JRE 메이저 버전 — **버전 JSON 이 없을 때만** 쓰는 폴백 추정.
    /// 정확한 값은 Mojang 의 `javaVersion.majorVersion` 이다(GameLauncher 참고).
    ///
    /// ⚠️ 예전에는 8 아니면 17 만 돌려줬다. 그래서 1.21 을 Java 17 로 띄우다
    ///    UnsupportedClassVersionError(class file version 65.0) 로 죽었다.
    static func javaMajor(_ versionId: String) -> Int {
        if isLegacy(versionId) { return 8 }
        // "25w14a" 같은 스냅샷이나 "26.2" 같은 새 체계는 1.x 가 아니다 — 최신으로 본다.
        guard let major = majorOf(versionId) else { return 21 }
        if major <= 16 { return 8 }
        if major <= 19 { return 17 }
        // 1.20 은 1.20.5 에서 21 로 넘어갔다.
        if major == 20 { return (minorOf(versionId) ?? 0) >= 5 ? 21 : 17 }
        return 21
    }

    /// 런처가 실제로 구동을 지원하는 버전인지. 안드로이드 `isVersionSupported` 와 동일 기준.
    static func isSupported(_ versionId: String) -> Bool {
        let id = versionId.lowercased()
        // 인데브/클래식/rd- 는 LWJGL2 이전이라 브릿지가 없다.
        if id.hasPrefix("rd-") || id.hasPrefix("c0.") || id.hasPrefix("inf-") { return false }
        return true
    }

    /// "1.20.5" → 5. 세 번째 자리가 없으면 nil.
    private static func minorOf(_ id: String) -> Int? {
        let parts = id.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return Int(parts[2].prefix { $0.isNumber })
    }

    private static func majorOf(_ id: String) -> Int? {
        guard id.hasPrefix("1.") else { return nil }
        let rest = id.dropFirst(2)
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }
}
