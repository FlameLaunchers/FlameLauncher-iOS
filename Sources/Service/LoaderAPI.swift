import Foundation

/// 모드 로더 종류. 안드로이드 LoaderSelectDialog 의 네 갈래와 동일.
enum ModLoader: String, CaseIterable, Identifiable {
    case vanilla, fabric, forge, neoforge, quilt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vanilla:  return "바닐라"
        case .fabric:   return "Fabric"
        case .forge:    return "Forge"
        case .neoforge: return "NeoForge"
        case .quilt:    return "Quilt"
        }
    }

    var emoji: String {
        switch self {
        case .vanilla:  return "🟩"
        case .fabric:   return "🧵"
        case .forge:    return "🔨"
        case .neoforge: return "⚒️"
        case .quilt:    return "🧶"
        }
    }

    var summary: String {
        switch self {
        case .vanilla:  return "모드 없이 순정 그대로 실행"
        case .fabric:   return "가볍고 빠른 모드 로더. 최신 버전 대응이 가장 빠름"
        case .forge:    return "가장 오래된 모드 로더. 대형 모드팩 대부분이 여기"
        case .neoforge: return "Forge 에서 갈라져 나온 최신 로더. 1.20.2+"
        case .quilt:    return "Fabric 호환 포크. 실험적"
        }
    }
}

/// 로더 빌드 한 개. Fabric/Quilt 의 loader 버전과 Forge/NeoForge 빌드를 하나로 묶었다
/// (안드로이드는 FabricLoaderEntry / ForgeLoaderEntry 로 나뉘어 있었지만 UI 가 쓰는
///  필드는 결국 같아서, 화면 코드가 두 타입을 분기하던 걸 없앴다).
struct LoaderBuild: Identifiable, Hashable {
    let version: String
    let stable: Bool
    let recommended: Bool

    var id: String { version }
}

enum LoaderAPI {

    // MARK: - Fabric / Quilt (둘 다 같은 meta 서버 스펙)

    private struct FabricLoaderEntry: Decodable {
        struct Loader: Decodable { let version: String; let stable: Bool? }
        let loader: Loader
    }

    static func fabricBuilds(mcVersion: String) async -> [LoaderBuild] {
        await metaBuilds(base: "https://meta.fabricmc.net/v2", mcVersion: mcVersion)
    }

    static func quiltBuilds(mcVersion: String) async -> [LoaderBuild] {
        await metaBuilds(base: "https://meta.quiltmc.org/v3", mcVersion: mcVersion)
    }

    private static func metaBuilds(base: String, mcVersion: String) async -> [LoaderBuild] {
        guard let url = URL(string: "\(base)/versions/loader/\(mcVersion)"),
              let entries = try? await HTTP.json([FabricLoaderEntry].self, from: url)
        else { return [] }
        // 첫 항목이 최신 = 추천.
        return entries.enumerated().map { i, e in
            LoaderBuild(version: e.loader.version, stable: e.loader.stable ?? false, recommended: i == 0)
        }
    }

    /// 인스턴스 디렉터리에 저장할 로더 프로필 JSON 원본.
    static func loaderProfile(
        _ loader: ModLoader, mcVersion: String, loaderVersion: String
    ) async throws -> Data {
        let base = loader == .quilt
            ? "https://meta.quiltmc.org/v3"
            : "https://meta.fabricmc.net/v2"
        let url = URL.lit("\(base)/versions/loader/\(mcVersion)/\(loaderVersion)/profile/json")
        return try await HTTP.data(url)
    }

    // MARK: - Forge

    /// JDK-8032636 회피용 "최소 안전 Forge 빌드".
    ///
    /// Java 8u20 부터 List.sort() 가 modCount 를 올리도록 바뀌었는데, 그 이전에 빌드된
    /// 구버전 FML 의 CoreModManager.sortTweakList() 는 LaunchWrapper 가 순회 중인
    /// blackboard "Tweaks" 리스트를 Collections.sort() 로 정렬한다 → 바로 다음 줄의
    /// Iterator.remove() 가 ConcurrentModificationException 을 던져 게임이 아예 안 뜬다.
    /// (모드 로드 이전 단계라 JVM 인자로도 못 고친다.) 아래 빌드 번호 이상만 노출한다.
    private static let minSafeForgeBuild: [String: Int] = ["1.7.10": 1558]

    static func forgeBuilds(mcVersion: String) async -> [LoaderBuild] {
        let promotions = await forgePromotions()
        let recommended = promotions["\(mcVersion)-recommended"]

        let all = await mavenVersions(
            "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
        )
        let prefix = "\(mcVersion)-"
        let floor = minSafeForgeBuild[mcVersion]

        return all
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .filter { version in
                guard let floor else { return true }
                let build = Int(version.split(separator: ".").last ?? "") ?? 0
                return build >= floor
            }
            .reversed()
            .map { LoaderBuild(version: $0, stable: $0 == recommended, recommended: $0 == recommended) }
    }

    static func forgeInstallerURL(mcVersion: String, forgeVersion: String) -> String {
        let full = "\(mcVersion)-\(forgeVersion)"
        return "https://maven.minecraftforge.net/net/minecraftforge/forge/\(full)/forge-\(full)-installer.jar"
    }

    private static func forgePromotions() async -> [String: String] {
        struct Promotions: Decodable { let promos: [String: String] }
        let url = URL.lit("https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")
        return (try? await HTTP.json(Promotions.self, from: url).promos) ?? [:]
    }

    // MARK: - NeoForge

    /// 버전 형식: "<MC_MINOR>.<MC_PATCH>.<BUILD>" (20.4.237 → MC 1.20.4).
    /// 1.20.1 NeoForge 는 net.neoforged:forge 의 별도 fork artifact 라 여기서 다루지 않는다.
    static func neoForgeBuilds(mcVersion: String) async -> [LoaderBuild] {
        let all = await mavenVersions(
            "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
        )
        let matching = all.filter { neoForgeVersionToMc($0) == mcVersion }
        guard !matching.isEmpty else { return [] }

        let recommended = matching.last { !$0.lowercased().contains("-beta") }
        return matching.reversed().map {
            LoaderBuild(version: $0, stable: !$0.lowercased().contains("-beta"),
                        recommended: $0 == recommended)
        }
    }

    static func neoForgeInstallerURL(_ version: String) -> String {
        "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(version)/neoforge-\(version)-installer.jar"
    }

    private static func neoForgeVersionToMc(_ v: String) -> String? {
        let parts = v.split(separator: "-")[0].split(separator: ".")
        guard parts.count >= 3, let minor = Int(parts[0]), let patch = Int(parts[1]) else { return nil }
        return patch == 0 ? "1.\(minor)" : "1.\(minor).\(patch)"
    }

    // MARK: - 공통

    /// maven-metadata.xml 에서 `<version>` 값만 뽑는다.
    /// 스키마가 고정이라 XMLParser 델리게이트를 다는 것보다 이게 짧고 충분하다.
    private static func mavenVersions(_ urlString: String) async -> [String] {
        guard let url = URL(string: urlString),
              let xml = try? await HTTP.text(url) else { return [] }
        return xml
            .components(separatedBy: "<version>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</version>").first }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 로더 선택 화면이 부르는 단일 진입점.
    static func builds(for loader: ModLoader, mcVersion: String) async -> [LoaderBuild] {
        switch loader {
        case .vanilla:  return []
        case .fabric:   return await fabricBuilds(mcVersion: mcVersion)
        case .quilt:    return await quiltBuilds(mcVersion: mcVersion)
        case .forge:    return await forgeBuilds(mcVersion: mcVersion)
        case .neoforge: return await neoForgeBuilds(mcVersion: mcVersion)
        }
    }
}
