import CommonCrypto
import CryptoKit
import Foundation

/// 컨텐츠 소스. 안드로이드 `ContentSource` 이식.
enum ContentSource: String, CaseIterable, Identifiable {
    case curseforge, modrinth

    var id: String { rawValue }
    var label: String { self == .curseforge ? "CurseForge" : "Modrinth" }
    var prefix: String { self == .curseforge ? "cf" : "mr" }
}

/// 컨텐츠 종류(탭). CurseForge classId / Modrinth project_type 양쪽으로 매핑된다.
enum ContentType: String, CaseIterable, Identifiable {
    case modpack, mod, resourcepack, shader, world

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modpack:      return String(localized: "모드팩")
        case .mod:          return String(localized: "모드")
        case .resourcepack: return String(localized: "리소스팩")
        case .shader:       return String(localized: "셰이더")
        case .world:        return String(localized: "맵")
        }
    }

    var emoji: String {
        switch self {
        case .modpack:      return "📦"
        case .mod:          return "🧩"
        case .resourcepack: return "🎨"
        case .shader:       return "✨"
        case .world:        return "🗺"
        }
    }

    /// CurseForge classId (Minecraft gameId=432 하위).
    var curseForgeClassId: Int {
        switch self {
        case .modpack:      return 4471
        case .mod:          return 6
        case .resourcepack: return 12
        case .shader:       return 6552
        case .world:        return 17
        }
    }

    /// Modrinth project_type facet. `nil` 이면 Modrinth 가 그 종류를 다루지 않는다.
    ///
    /// ⚠️ 맵은 Modrinth 에 없다. 예전에는 datapack 으로 대신 물었는데, 그 facet 은
    ///    **모드를 돌려준다**(Terralith 등이 datapack 태그를 단 mod 다). 그 결과가
    ///    맵으로 취급돼 모드 jar 가 saves/ 에 떨어졌다 — 아예 탭에서 뺀다.
    var modrinthProjectType: String? {
        switch self {
        case .modpack:      return "modpack"
        case .mod:          return "mod"
        case .resourcepack: return "resourcepack"
        case .shader:       return "shader"
        case .world:        return nil
        }
    }

    /// 소스가 실제로 제공하는 탭만 남긴다.
    static func tabs(for source: ContentSource) -> [ContentType] {
        source == .modrinth ? allCases.filter { $0.modrinthProjectType != nil } : allCases
    }

    /// 인스턴스 안에서 설치될 폴더.
    var installFolder: String {
        switch self {
        case .modpack:      return "."
        case .mod:          return "mods"
        case .resourcepack: return "resourcepacks"
        case .shader:       return "shaderpacks"
        case .world:        return "saves"
        }
    }
}

/// 소스 무관 공통 컨텐츠 모델. 목록 화면은 이것만 쓰고, 상세/설치에서 source 로 분기한다.
struct ContentItem: Identifiable, Hashable {
    let source: ContentSource
    /// 어느 탭에서 온 것인지. 검색은 project_type/classId 로 걸러서 오므로 이 값이 곧 종류다.
    /// 설치 경로(모드팩이냐 아니냐, 어느 폴더냐)를 이걸로 정한다 — 파일 확장자로는 못 가린다.
    let type: ContentType
    let id: String
    let name: String
    let summary: String
    let downloads: Int
    let logoURL: URL?
    let author: String?

    /// 설치 추적용 안정 키 ("cf:12345" / "mr:AABBccdd").
    var trackKey: String { "\(source.prefix):\(id)" }

    var downloadsLabel: String {
        switch downloads {
        case 1_000_000...: return String(format: "%.1fM", Double(downloads) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(downloads) / 1_000)
        default:           return "\(downloads)"
        }
    }
}

/// 이 파일이 **반드시** 같이 있어야 하는 다른 프로젝트.
///
/// 선택(optional)·내장(embedded)·충돌(incompatible)은 담지 않는다 — 자동으로 끌어오면
/// 안 되는 것들이다. 필수만 담는다.
struct ContentDependency: Hashable {
    /// 같은 소스(CurseForge/Modrinth) 안에서의 프로젝트 id.
    let projectId: String
}

/// 설치 가능한 파일 하나(모드/모드팩의 특정 릴리스).
struct ContentFile: Identifiable, Hashable {
    let id: String
    let displayName: String
    let fileName: String
    let downloadURL: String?
    let gameVersions: [String]
    let loaders: [String]
    /// 이 파일이 요구하는 다른 모드들. 설치할 때 같이 받는다.
    var requiredDependencies: [ContentDependency] = []
}

// MARK: - Modrinth

/// Modrinth API v2.
///
/// 주의: Modrinth 는 식별 가능한 User-Agent 를 요구한다. 일반 UA 는 차단될 수 있다.
enum ModrinthAPI {
    private static let base = "https://api.modrinth.com/v2"
    private static let headers = [
        "User-Agent": "FlameLaunchers/FlameLauncher/2.0 (kr.co.donghyun.flamelauncher)",
        "Accept": "application/json",
    ]

    private struct SearchResponse: Decodable {
        struct Hit: Decodable {
            let project_id: String
            let title: String
            let description: String
            let downloads: Int
            let icon_url: String?
            let author: String?
        }
        let hits: [Hit]
    }

    static func search(
        query: String, type: ContentType, gameVersion: String?, loader: String?,
        limit: Int = 30, offset: Int = 0
    ) async -> [ContentItem] {
        guard let projectType = type.modrinthProjectType else { return [] }

        // facets: [["project_type:modpack"],["versions:1.20.1"],["categories:fabric"]] (AND)
        var groups = ["[\"project_type:\(projectType)\"]"]
        if let gameVersion, !gameVersion.isEmpty { groups.append("[\"versions:\(gameVersion)\"]") }
        if let loader, !loader.isEmpty { groups.append("[\"categories:\(loader.lowercased())\"]") }

        var comps = URLComponents(string: "\(base)/search")!
        comps.queryItems = [
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset)),
            .init(name: "index", value: "downloads"),     // 인기순
            .init(name: "facets", value: "[" + groups.joined(separator: ",") + "]"),
        ]
        if !query.isEmpty { comps.queryItems?.append(.init(name: "query", value: query)) }

        guard let url = comps.url,
              let response = try? await HTTP.json(SearchResponse.self, from: url, headers: headers)
        else { return [] }

        return response.hits.map {
            ContentItem(source: .modrinth, type: type, id: $0.project_id, name: $0.title,
                        summary: $0.description, downloads: $0.downloads,
                        logoURL: $0.icon_url.flatMap(URL.init(string:)), author: $0.author)
        }
    }

    private struct Project: Decodable {
        struct GalleryImage: Decodable {
            let url: String
            let featured: Bool?
        }
        let body: String?
        let title: String
        let gallery: [GalleryImage]?
    }

    /// 상세 화면의 긴 설명(markdown).
    static func description(id: String) async -> String? {
        guard let url = URL(string: "\(base)/project/\(id)") else { return nil }
        return try? await HTTP.json(Project.self, from: url, headers: headers).body
    }

    /// 상세 화면 위쪽에 넘겨 보는 스크린샷. featured 를 앞에 둔다.
    static func screenshots(id: String) async -> [URL] {
        guard let url = URL(string: "\(base)/project/\(id)") else { return [] }
        guard let project = try? await HTTP.json(Project.self, from: url, headers: headers) else { return [] }
        let images = project.gallery ?? []
        return (images.filter { $0.featured == true } + images.filter { $0.featured != true })
            .compactMap { URL(string: $0.url) }
    }

    private struct Version: Decodable {
        struct File: Decodable {
            let url: String
            let filename: String
            let primary: Bool
        }
        struct Dependency: Decodable {
            let project_id: String?
            let dependency_type: String
        }
        let id: String
        let name: String
        let game_versions: [String]
        let loaders: [String]
        let files: [File]
        let dependencies: [Dependency]?
    }

    static func files(id: String, gameVersion: String?, loader: String?) async -> [ContentFile] {
        var comps = URLComponents(string: "\(base)/project/\(id)/version")!
        var items: [URLQueryItem] = []
        if let gameVersion, !gameVersion.isEmpty {
            items.append(.init(name: "game_versions", value: "[\"\(gameVersion)\"]"))
        }
        if let loader, !loader.isEmpty {
            items.append(.init(name: "loaders", value: "[\"\(loader.lowercased())\"]"))
        }
        comps.queryItems = items.isEmpty ? nil : items

        guard let url = comps.url,
              let versions = try? await HTTP.json([Version].self, from: url, headers: headers)
        else { return [] }

        return versions.compactMap { v in
            guard let file = v.files.first(where: \.primary) ?? v.files.first else { return nil }
            // "required" 만 가져온다. optional/embedded/incompatible 을 끌어오면
            // 쓰지도 않을 모드가 딸려오거나, 충돌하는 모드를 설치하게 된다.
            let required = (v.dependencies ?? [])
                .filter { $0.dependency_type == "required" }
                .compactMap(\.project_id)
                .map(ContentDependency.init(projectId:))
            return ContentFile(id: v.id, displayName: v.name, fileName: file.filename,
                               downloadURL: file.url, gameVersions: v.game_versions,
                               loaders: v.loaders, requiredDependencies: required)
        }
    }
}

// MARK: - CurseForge

/// CurseForge API v1.
///
/// ⚠️ API 키가 필요하다. 안드로이드는 `local.properties` → BuildConfig 로 넣었고,
///    여기서는 Info.plist 의 `CURSEFORGE_API_KEY` 를 읽는다 (없으면 CurseForge 탭이
///    빈 목록으로 뜨고 Modrinth 만 동작한다 — 키 없이도 앱이 죽지 않게).
enum CurseForgeAPI {
    private static let base = "https://api.curseforge.com/v1"
    private static let minecraftGameId = 432

    /// 키는 번들의 `Secrets.plist` 에서 읽는다 — 저장소에 올리지 않는 파일이라
    /// 안드로이드의 `local.properties` 와 같은 역할이다.
    ///
    /// 평문이 아니라 **AES-256-CBC 암호문**이 들어 있다(Scripts/write-secrets.sh 가 만든다).
    /// 열쇠는 `SHA-256(암호구절)`, 암호구절은 저장소 밖에 둔다.
    /// ⚠️ 난독화지 보안이 아니다 — 복호화에 필요한 게 전부 앱 안에 있다. 목적은 소스·저장소·
    ///    `strings` 덤프에서 평문 키를 없애는 것뿐이고, 남용되면 키를 새로 발급하는 수밖에 없다.
    /// (평문을 넣던 옛 Info.plist 경로도 계속 지원한다 — CI 가 빌드 설정으로 주입할 수 있게)
    static let apiKey: String = {
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url) {
            if let cipher = dict["CURSEFORGE_KEY_CIPHER"] as? String,
               let iv = dict["CURSEFORGE_KEY_IV"] as? String,
               let pass = dict["CURSEFORGE_KEY_PASS"] as? String,
               let key = decryptKey(cipherB64: cipher, ivB64: iv, passB64: pass) {
                return key
            }
            if let key = dict["CURSEFORGE_API_KEY"] as? String, !key.isEmpty { return key }
        }
        return Bundle.main.object(forInfoDictionaryKey: "CURSEFORGE_API_KEY") as? String ?? ""
    }()

    /// AES-256-CBC 복호화. CryptoKit 은 CBC 를 안 다뤄서 CommonCrypto 를 쓴다.
    private static func decryptKey(cipherB64: String, ivB64: String, passB64: String) -> String? {
        guard let cipherData = Data(base64Encoded: cipherB64),
              let iv = Data(base64Encoded: ivB64),
              let pass = Data(base64Encoded: passB64),
              iv.count == kCCBlockSizeAES128, !cipherData.isEmpty
        else { return nil }

        let aesKey = Data(SHA256.hash(data: pass))
        var out = Data(count: cipherData.count + kCCBlockSizeAES128)
        let outCount = out.count   // 클로저 안에서 out 을 또 읽으면 배타 접근 위반이다
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBuf in
            cipherData.withUnsafeBytes { inBuf in
                iv.withUnsafeBytes { ivBuf in
                    aesKey.withUnsafeBytes { keyBuf in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBuf.baseAddress, kCCKeySizeAES256,
                                ivBuf.baseAddress,
                                inBuf.baseAddress, cipherData.count,
                                outBuf.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: out.prefix(moved), encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var isConfigured: Bool { !apiKey.isEmpty }

    private static var headers: [String: String] {
        ["x-api-key": apiKey, "Accept": "application/json"]
    }

    private struct SearchResponse: Decodable {
        struct Mod: Decodable {
            struct Logo: Decodable { let url: String? }
            struct Author: Decodable { let name: String? }
            let id: Int
            let name: String
            let summary: String
            let downloadCount: Double
            let logo: Logo?
            let authors: [Author]?
        }
        let data: [Mod]
    }

    static func search(
        query: String, type: ContentType, gameVersion: String?, loader: String?,
        limit: Int = 30, offset: Int = 0
    ) async -> [ContentItem] {
        guard isConfigured else { return [] }

        var comps = URLComponents(string: "\(base)/mods/search")!
        var items: [URLQueryItem] = [
            .init(name: "gameId", value: String(minecraftGameId)),
            .init(name: "classId", value: String(type.curseForgeClassId)),
            .init(name: "sortField", value: "2"),        // TotalDownloads
            .init(name: "sortOrder", value: "desc"),
            .init(name: "pageSize", value: String(limit)),
            .init(name: "index", value: String(offset)),
        ]
        if !query.isEmpty { items.append(.init(name: "searchFilter", value: query)) }
        if let gameVersion, !gameVersion.isEmpty {
            items.append(.init(name: "gameVersion", value: gameVersion))
        }
        if let loader, let loaderType = curseForgeLoaderType(loader) {
            items.append(.init(name: "modLoaderType", value: String(loaderType)))
        }
        comps.queryItems = items

        guard let url = comps.url,
              let response = try? await HTTP.json(SearchResponse.self, from: url, headers: headers)
        else { return [] }

        return response.data.map {
            ContentItem(source: .curseforge, type: type, id: String($0.id), name: $0.name,
                        summary: $0.summary, downloads: Int($0.downloadCount),
                        logoURL: $0.logo?.url.flatMap(URL.init(string:)),
                        author: $0.authors?.first?.name)
        }
    }

    private struct DescriptionResponse: Decodable { let data: String }

    private struct ModResponse: Decodable {
        struct Mod: Decodable {
            struct Screenshot: Decodable { let url: String }
            let screenshots: [Screenshot]?
        }
        let data: Mod
    }

    static func description(id: String) async -> String? {
        guard isConfigured, let url = URL(string: "\(base)/mods/\(id)/description") else { return nil }
        return try? await HTTP.json(DescriptionResponse.self, from: url, headers: headers).data
    }

    /// 상세 화면 위쪽에 넘겨 보는 스크린샷.
    static func screenshots(id: String) async -> [URL] {
        guard isConfigured, let url = URL(string: "\(base)/mods/\(id)") else { return [] }
        guard let res = try? await HTTP.json(ModResponse.self, from: url, headers: headers) else { return [] }
        return (res.data.screenshots ?? []).compactMap { URL(string: $0.url) }
    }

    private struct FilesResponse: Decodable {
        struct File: Decodable {
            let id: Int
            let displayName: String
            let fileName: String
            let downloadUrl: String?
            let gameVersions: [String]
            let dependencies: [Dependency]?
        }
        /// relationType 3 = RequiredDependency (CurseForge 문서 기준).
        struct Dependency: Decodable {
            let modId: Int
            let relationType: Int
        }
        let data: [File]
    }

    static func files(id: String, gameVersion: String?) async -> [ContentFile] {
        guard isConfigured else { return [] }
        var comps = URLComponents(string: "\(base)/mods/\(id)/files")!
        comps.queryItems = [.init(name: "pageSize", value: "50")]
        if let gameVersion, !gameVersion.isEmpty {
            comps.queryItems?.append(.init(name: "gameVersion", value: gameVersion))
        }

        guard let url = comps.url,
              let response = try? await HTTP.json(FilesResponse.self, from: url, headers: headers)
        else { return [] }

        return response.data.map { f in
            ContentFile(id: String(f.id), displayName: f.displayName, fileName: f.fileName,
                        // downloadUrl 이 null 인 파일(배포 거부 모드)은 CDN 경로를 조립해 시도한다.
                        downloadURL: f.downloadUrl ?? cdnURL(fileId: f.id, fileName: f.fileName),
                        gameVersions: f.gameVersions,
                        loaders: f.gameVersions.filter { ["Fabric", "Forge", "NeoForge", "Quilt"].contains($0) },
                        // 3 = 필수. 2(선택)·4(도구)·5(비호환)·6(포함)은 가져오지 않는다.
                        requiredDependencies: (f.dependencies ?? [])
                            .filter { $0.relationType == 3 }
                            .map { ContentDependency(projectId: String($0.modId)) })
        }
    }

    // MARK: - 모드팩 manifest 용 배치 조회

    private struct ManifestFilesResponse: Decodable {
        struct Entry: Decodable {
            let id: Int
            let modId: Int
            let fileName: String
            let downloadUrl: String?
        }
        let data: [Entry]
    }

    private struct ModsResponse: Decodable {
        struct Entry: Decodable {
            let id: Int
            let classId: Int?
        }
        let data: [Entry]
    }

    /// manifest 의 `files[].fileID` 들을 한 번에 조회한다.
    /// `downloadUrl` 이 null(서드파티 다운로드 차단)이면 CDN 규칙으로 만들어 준다.
    static func fileInfos(_ fileIds: [Int]) async -> [Int: (fileName: String, url: String?)] {
        guard isConfigured, !fileIds.isEmpty,
              let url = URL(string: "\(base)/mods/files") else { return [:] }

        var out: [Int: (fileName: String, url: String?)] = [:]
        // CF 는 한 번에 받는 개수에 제한이 있다 — 넉넉히 나눠 보낸다.
        for chunk in stride(from: 0, to: fileIds.count, by: 200).map({
            Array(fileIds[$0..<min($0 + 200, fileIds.count)])
        }) {
            guard let body = try? JSONSerialization.data(withJSONObject: ["fileIds": chunk]),
                  let res = try? await HTTP.post(ManifestFilesResponse.self, url: url, body: body,
                                                 contentType: "application/json", headers: headers)
            else { continue }
            for e in res.data {
                out[e.id] = (e.fileName, e.downloadUrl ?? cdnURL(fileId: e.id, fileName: e.fileName))
            }
        }
        return out
    }

    /// 프로젝트의 classId 를 한 번에 조회한다.
    ///
    /// ⚠️ manifest 의 `files[]` 는 {projectID, fileID} 뿐이라 모드/리소스팩/셰이더팩 구분이 없다.
    ///    classId 를 봐야 올바른 폴더에 넣을 수 있다 — 안 하면 리소스팩까지 mods/ 로 들어가
    ///    게임이 인식하지 못한다. (안드로이드판과 같은 이유)
    static func classIds(_ modIds: [Int]) async -> [Int: Int] {
        guard isConfigured, !modIds.isEmpty,
              let url = URL(string: "\(base)/mods") else { return [:] }

        var out: [Int: Int] = [:]
        for chunk in stride(from: 0, to: modIds.count, by: 200).map({
            Array(modIds[$0..<min($0 + 200, modIds.count)])
        }) {
            guard let body = try? JSONSerialization.data(withJSONObject: ["modIds": chunk]),
                  let res = try? await HTTP.post(ModsResponse.self, url: url, body: body,
                                                 contentType: "application/json", headers: headers)
            else { continue }
            for e in res.data where e.classId != nil { out[e.id] = e.classId! }
        }
        return out
    }

    /// downloadUrl 이 비어 있을 때 쓰는 edge CDN 경로 규칙 (id 를 4+3 으로 쪼갠다).
    private static func cdnURL(fileId: Int, fileName: String) -> String? {
        let s = String(fileId)
        guard s.count >= 5 else { return nil }
        let part1 = String(s.prefix(s.count - 3))
        let part2 = String(Int(s.suffix(3)) ?? 0)
        let escaped = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        return "https://edge.forgecdn.net/files/\(part1)/\(part2)/\(escaped)"
    }

    private static func curseForgeLoaderType(_ loader: String) -> Int? {
        switch loader.lowercased() {
        case "forge":    return 1
        case "fabric":   return 4
        case "quilt":    return 5
        case "neoforge": return 6
        default:         return nil
        }
    }
}

/// 두 소스를 하나의 호출로 감싸는 파사드 — 화면 코드가 소스별 분기를 하지 않게.
enum ContentAPI {
    static func search(
        source: ContentSource, query: String, type: ContentType,
        gameVersion: String?, loader: String?, offset: Int = 0
    ) async -> [ContentItem] {
        switch source {
        case .modrinth:
            return await ModrinthAPI.search(query: query, type: type, gameVersion: gameVersion,
                                            loader: loader, offset: offset)
        case .curseforge:
            return await CurseForgeAPI.search(query: query, type: type, gameVersion: gameVersion,
                                              loader: loader, offset: offset)
        }
    }

    static func description(_ item: ContentItem) async -> String? {
        switch item.source {
        case .modrinth:   return await ModrinthAPI.description(id: item.id)
        case .curseforge: return await CurseForgeAPI.description(id: item.id)
        }
    }

    /// 상세 화면의 스크린샷 목록. 없으면 빈 배열이다(안드로이드 상세 화면과 같은 자리).
    static func screenshots(_ item: ContentItem) async -> [URL] {
        switch item.source {
        case .modrinth:   return await ModrinthAPI.screenshots(id: item.id)
        case .curseforge: return await CurseForgeAPI.screenshots(id: item.id)
        }
    }

    /// 이 인스턴스에 맞는 파일 하나를 고른다. 의존성을 자동으로 받을 때 쓴다.
    ///
    /// 목록은 대개 최신순이라 맨 앞을 고르면 되지만, 서버가 버전·로더로 걸러 주지 않는
    /// 경우가 있어서(CurseForge 의 loaders 는 gameVersions 에서 짜낸 값이다) 한 번 더 거른다.
    static func bestFile(source: ContentSource, projectId: String,
                         gameVersion: String, loader: String?) async -> ContentFile? {
        let files: [ContentFile]
        switch source {
        case .modrinth:
            files = await ModrinthAPI.files(id: projectId, gameVersion: gameVersion, loader: loader)
        case .curseforge:
            files = await CurseForgeAPI.files(id: projectId, gameVersion: gameVersion)
        }
        let matching = files.filter { file in
            guard file.gameVersions.isEmpty || file.gameVersions.contains(gameVersion) else { return false }
            guard let loader, !loader.isEmpty, !file.loaders.isEmpty else { return true }
            return file.loaders.contains { $0.caseInsensitiveCompare(loader) == .orderedSame }
        }
        return matching.first ?? files.first
    }

    static func files(_ item: ContentItem, gameVersion: String?, loader: String?) async -> [ContentFile] {
        switch item.source {
        case .modrinth:   return await ModrinthAPI.files(id: item.id, gameVersion: gameVersion, loader: loader)
        case .curseforge: return await CurseForgeAPI.files(id: item.id, gameVersion: gameVersion)
        }
    }
}
