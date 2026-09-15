import Foundation
import Observation

enum InstanceType: String, Codable {
    case vanilla = "VANILLA"
    case modpack = "MODPACK"
    case fabric  = "FABRIC"
}

/// 안드로이드 `data.instance.InstanceMeta` 를 그대로 옮긴 인스턴스 메타.
/// 필드명을 맞춰뒀기 때문에 안드로이드에서 내보낸 instance.json 을 그대로 읽을 수 있다.
struct InstanceMeta: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: InstanceType
    var mcVersion: String
    var loaderType: String?
    var loaderVersion: String?
    var mainClass: String = "net.minecraft.client.main.Main"
    var extraJars: [String] = []
    var assetIndexId: String = ""
    var iconEmoji: String = "🌿"
    /// 다운로드한 인스턴스 아이콘 파일의 **상대** 경로(<instanceDir>/icon.png).
    /// ⚠️ 안드로이드는 절대경로를 넣었지만 iOS 는 앱 컨테이너 경로가 업데이트마다 바뀌므로
    ///    절대경로를 저장하면 재설치 후 전부 깨진다. 상대경로로 저장하고 읽을 때 조립한다.
    var iconPath: String?
    var gameJvmArgs: [String] = []
    var gameArgs: [String] = []
    var sourceModId: Int?
    /// "zink" / "gl4es" / "mobileglues" / "krypton". nil 이면 전역 기본 렌더러.
    var rendererId: String?
    /// 마지막으로 실행한 시각. 목록을 최근 순으로 세우는 데 쓴다.
    ///
    /// ⚠️ 선택값이다. 안드로이드가 쓴 instance.json 이나 이 필드가 생기기 전에 만든
    ///    인스턴스에는 없다 — 없으면 이름순 뒤로 간다.
    var lastPlayedAt: Date?

    var dir: URL { Paths.instance(id) }
    var iconURL: URL? { iconPath.map { dir.appending(path: $0) } }

    /// 목록/실행바에 쓰는 로더 표기. ("Fabric 0.16.9" / "Vanilla")
    var loaderLabel: String {
        switch loaderType?.lowercased() {
        case "fabric":   return "Fabric \(loaderVersion ?? "")"
        case "forge":    return "Forge \(loaderVersion ?? "")"
        case "neoforge": return "NeoForge \(loaderVersion ?? "")"
        case "quilt":    return "Quilt \(loaderVersion ?? "")"
        default:         return "Vanilla"
        }
    }

    /// 로더가 없는 바닐라면 마인크래프트 아이콘, 있으면 로더 아이콘.
    /// 기본 아이콘으로 쓸 자산 이름. nil 이면 이모지(`fallbackSymbol`)로 떨어진다.
    ///
    /// 바닐라는 이모지(🟩)로 그리고 있었는데, 옆에 놓인 모드팩들이 실제 로고를 받아
    /// 쓰기 때문에 혼자만 그림이 아니라 글자로 보였다.
    /// 모드팩(sourceModId)은 자기 로고를 내려받아 쓰므로 여기 해당하지 않는다.
    var fallbackAsset: String? {
        guard sourceModId == nil else { return nil }
        switch loaderType?.lowercased() {
        case nil, "", "vanilla": return "minecraft"
        default:                 return nil
        }
    }

    var fallbackSymbol: String {
        switch loaderType?.lowercased() {
        case "fabric":   return "🧵"
        case "forge":    return "🔨"
        case "neoforge": return "⚒️"
        case "quilt":    return "🧶"
        default:         return sourceModId != nil ? "📦" : "🟩"
        }
    }
}

/// 안드로이드 `InstanceManager` (object) 대응. 디스크가 유일한 진실이고,
/// 화면은 `reload()` 로 다시 읽는다 — 안드로이드와 같은 방식.
@Observable
final class InstanceStore {
    static let shared = InstanceStore()

    private(set) var instances: [InstanceMeta] = []

    private static let metaFile = "instance.json"

    private init() { reload() }

    func reload() {
        Paths.ensureDir(Paths.instances)
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Paths.instances, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        instances = dirs
            .compactMap { loadMeta(dir: $0) }
            .sorted(by: Self.recentFirst)
    }

    /// 최근 실행한 것이 위로. 실행한 적 없는 것들끼리는 이름순.
    ///
    /// 방금 돌린 버전을 목록 한가운데서 다시 찾는 게 번거로워서 이렇게 세운다.
    /// 이름순을 완전히 버리지는 않는다 — 한 번도 안 돌린 인스턴스는 순서가 고정되어야
    /// 어디 있는지 기억할 수 있다.
    static func recentFirst(_ a: InstanceMeta, _ b: InstanceMeta) -> Bool {
        switch (a.lastPlayedAt, b.lastPlayedAt) {
        case let (x?, y?): return x > y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 이 인스턴스를 방금 실행했다고 기록하고 목록을 다시 세운다.
    func notePlayed(_ meta: InstanceMeta) {
        guard var stored = instances.first(where: { $0.id == meta.id }) ?? loadMeta(dir: meta.dir)
        else { return }
        stored.lastPlayedAt = .now
        save(stored)
        reload()
    }

    // ⚠️ 여기에 "jetsam 을 겪으면 아틀라스 상한을 낮춘다" 는 적응 로직이 있었다. 지웠다.
    //
    //    측정해 보니 아틀라스는 footprint 의 8% 뿐이었고(익명 1135 + 압축 1528 중
    //    아틀라스 256), 진짜 원인은 LWJGL 을 지나는 네이티브 할당 전체였다.
    //    그건 파일 기반 매핑 할당자로 뿌리부터 해결했다 — 실측 3069 MB → 1150 MB.
    //    (Sources/Natives/flame_alloc.c · JvmSettings.allocatorArgs)
    //
    //    남겨 두면 해만 끼친다: 상한이 1024 까지 내려가자 MobileGlues 가 아틀라스가 아니라
    //    **마인크래프트의 메인 렌더 타깃**(=화면 크기 텍스처)을 줄여서 화면이 잘렸다.
    //      MGTEX 1533x707 -> 766x353 (상한 1024 강제)

    func loadMeta(dir: URL) -> InstanceMeta? {
        guard let data = try? Data(contentsOf: dir.appending(path: Self.metaFile)) else { return nil }
        return try? JSONDecoder().decode(InstanceMeta.self, from: data)
    }

    func loadMeta(id: String) -> InstanceMeta? { loadMeta(dir: Paths.instance(id)) }

    func save(_ meta: InstanceMeta) {
        Paths.ensureDir(meta.dir)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: meta.dir.appending(path: Self.metaFile), options: .atomic)
        }
        reload()
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: Paths.instance(id))
        reload()
    }

    func updateRendererId(_ id: String, rendererId: String?) {
        guard var meta = loadMeta(id: id) else { return }
        meta.rendererId = rendererId
        save(meta)
    }

    /// mods/ 안의 .jar 개수 — 부팅 오버레이의 "모드 N개 로딩" 문구에 쓴다.
    func modCount(_ meta: InstanceMeta) -> Int {
        let mods = meta.dir.appending(path: "mods")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: mods.path)) ?? []
        return files.filter { $0.hasSuffix(".jar") }.count
    }

    // ── id 규칙 (안드로이드와 동일하게 유지: 두 플랫폼이 같은 폴더명을 쓴다) ──
    static func vanillaId(_ versionId: String) -> String { "vanilla_\(versionId)" }

    static func modpackId(_ modName: String) -> String {
        let cleaned = modName.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        return "modpack_" + String(cleaned.prefix(40))
    }

    static func loaderId(_ loader: String, mc: String, loaderVersion: String) -> String {
        "\(loader)_\(mc)_" + loaderVersion.replacingOccurrences(of: ".", with: "_")
    }

    /// "새로 설치" 마다 같은 버전이라도 별개 인스턴스로 분리하기 위한 짧은 토큰.
    static func newToken() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    static func withToken(_ baseId: String, _ token: String?) -> String {
        guard let token, !token.isEmpty else { return baseId }
        return "\(baseId)_\(token)"
    }
}
