import Foundation

/// 모드/리소스팩/셰이더/맵 파일 하나를 기존 인스턴스에 설치하고,
/// 모드팩(.mrpack / CurseForge zip)은 새 인스턴스로 풀어준다.
///
/// 안드로이드 쪽 ModImporter / MrPackInstaller / ModPackInstaller / ResourcePackImporter /
/// MapImporter 다섯 파일이 하던 일을 합쳤다 — 다섯 다 "받아서 → 알맞은 폴더에 넣는다"
/// 였고, 다른 건 목적지 폴더와 압축 해제 여부뿐이었다.
struct ContentInstaller {
    let onProgress: @Sendable (DownloadProgress) -> Void

    // MARK: - 단일 파일 (모드 / 리소스팩 / 셰이더 / 맵)

    /// 기존 인스턴스에 파일 하나를 설치한다.
    func installFile(_ file: ContentFile, type: ContentType, source: ContentSource,
                     into meta: InstanceMeta) async throws {
        guard let urlString = file.downloadURL else {
            throw LoaderInstallError.unsupported(
                String(localized: "이 파일은 배포자가 서드파티 다운로드를 막아둬서 앱에서 받을 수 없습니다.")
            )
        }
        onProgress(DownloadProgress(phase: .installingLoader, fileName: file.fileName))

        let folder = meta.dir.appending(path: type.installFolder)
        Paths.ensureDir(folder)

        // 맵(.zip)은 saves/ 아래에 풀어야 월드로 인식된다. 나머지는 파일 그대로.
        if type == .world, file.fileName.hasSuffix(".zip") {
            let tmp = Paths.caches.appending(path: file.fileName)
            try await HTTP.download(urlString, to: tmp)
            try Zip.unzip(tmp, to: folder)
            try? FileManager.default.removeItem(at: tmp)
        } else {
            try await HTTP.download(urlString, to: folder.appending(path: file.fileName))
        }

        // 모드 하나만 넣을 때도 Sodium 이면 Podium 이 같이 필요하다.
        if type == .mod {
            await installRequiredDependencies(of: file, source: source, into: meta)
            await Self.installPodiumIfSodium(
                instanceDir: meta.dir, mcVersion: meta.mcVersion,
                loader: meta.loaderType.flatMap(ModLoader.init(rawValue:)), onProgress: onProgress)
        }
        onProgress(DownloadProgress(phase: .done))
    }

    /// 이 파일이 요구하는 모드를 **같이** 설치한다.
    ///
    /// 없으면 게임이 부팅 중에 죽는다 — 원인이 런처처럼 보이지도 않는다:
    ///   "Mod File lucky-block-…jar needs language provider kotlinforforge to load"
    /// 의존성이 또 의존성을 갖는 경우가 흔해서(Kotlin For Forge → …) 너비 우선으로 훑는다.
    ///
    /// ⚠️ 필수(required)만 따라간다. 선택 의존성까지 끌어오면 쓰지도 않을 모드가 쌓이고,
    ///    비호환 관계를 잘못 해석하면 충돌하는 모드를 설치하게 된다.
    private func installRequiredDependencies(
        of file: ContentFile, source: ContentSource, into meta: InstanceMeta
    ) async {
        var queue = file.requiredDependencies.map(\.projectId)
        var seen = Set(queue)
        var depth = 0

        // 순환·폭주 방지. 실제 모드팩도 이 정도 깊이를 넘지 않는다.
        while !queue.isEmpty, depth < 8 {
            depth += 1
            var next: [String] = []

            for projectId in queue {
                guard let dependency = await ContentAPI.bestFile(
                    source: source, projectId: projectId,
                    gameVersion: meta.mcVersion, loader: meta.loaderType)
                else { continue }

                // 이미 있는 파일은 건너뛴다(같은 의존성을 여러 모드가 요구한다).
                let dest = meta.dir.appending(path: ContentType.mod.installFolder)
                    .appending(path: dependency.fileName)
                if FileManager.default.fileExists(atPath: dest.path) { continue }

                guard let urlString = dependency.downloadURL else { continue }
                onProgress(DownloadProgress(phase: .installingLoader,
                                            fileName: "의존성: \(dependency.fileName)"))
                Paths.ensureDir(dest.deletingLastPathComponent())
                try? await HTTP.download(urlString, to: dest)

                for further in dependency.requiredDependencies
                where seen.insert(further.projectId).inserted {
                    next.append(further.projectId)
                }
            }
            queue = next
        }
    }

    /// 셰이더팩은 **Iris(또는 Oculus)가 있어야** 게임이 읽는다.
    /// 없으면 shaderpacks/ 에 넣어도 게임에 셰이더 화면 자체가 없어서
    /// "설치했는데 아무 일도 안 일어난다"로 보인다 — 설치 직후 알려준다.
    static func shaderPrerequisiteNote(for meta: InstanceMeta) -> String? {
        let mods = meta.dir.appending(path: "mods")
        let jars = (try? FileManager.default.contentsOfDirectory(atPath: mods.path)) ?? []
        let hasIris = jars.contains {
            let name = $0.lowercased()
            return name.hasPrefix("iris") || name.hasPrefix("oculus")
        }
        guard !hasIris else { return nil }
        return String(localized: "이 인스턴스에 Iris 가 없어서 게임이 셰이더를 읽지 못합니다. ")
             + String(localized: "모드 탭에서 Iris 를 먼저 설치하고, 렌더러는 Zink 를 쓰세요.")
    }

    // MARK: - 모드팩 → 새 인스턴스

    /// 모드팩을 새 인스턴스로 설치한다.
    ///
    /// 배포처마다 아카이브 형식이 다르다 — **압축을 푼 뒤 내용으로 판별**한다.
    ///  - Modrinth `.mrpack` → `modrinth.index.json` (파일 URL 이 인덱스에 직접 들어있다)
    ///  - CurseForge `.zip`  → `manifest.json` (프로젝트/파일 ID 만 있어서 API 로 풀어야 한다)
    func installModpack(
        _ item: ContentItem, file: ContentFile, versions: [VersionEntry]
    ) async throws -> InstanceMeta {
        guard let urlString = file.downloadURL else {
            throw LoaderInstallError.unsupported(String(localized: "다운로드 URL 이 없습니다."))
        }

        onProgress(DownloadProgress(phase: .installingLoader, fileName: file.fileName))
        let archive = Paths.caches.appending(path: file.fileName)
        try? FileManager.default.removeItem(at: archive)
        try await HTTP.download(urlString, to: archive)

        guard let indexData = try Zip.extract("modrinth.index.json", from: archive),
              let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let deps = index["dependencies"] as? [String: String],
              let mcVersion = deps["minecraft"]
        else {
            // CurseForge 팩이면 manifest.json 이 들어있다.
            return try await installCurseForgePack(item, archive: archive, versions: versions)
        }

        let (loader, loaderVersion) = Self.loaderFrom(dependencies: deps)
        let packName = (index["name"] as? String) ?? item.name

        let id = InstanceStore.withToken(InstanceStore.modpackId(packName), InstanceStore.newToken())
        var meta = InstanceMeta(id: id, name: packName, type: .modpack, mcVersion: mcVersion)
        meta.sourceModId = Int(item.id)
        Paths.ensureDir(meta.dir)

        // 1) 바닐라 베이스
        guard let entry = versions.first(where: { $0.id == mcVersion }) else {
            throw LoaderInstallError.unsupported("모드팩이 요구하는 MC \(mcVersion) 을 목록에서 못 찾았습니다.")
        }
        let prepared = try await MinecraftDownloader(
            instanceDir: meta.dir, versionEntry: entry, onProgress: onProgress
        ).prepare()
        meta.assetIndexId = prepared.assetIndexId
        meta.mainClass = prepared.mainClass

        // 2) 로더
        if let loader, let loaderVersion {
            let installer = LoaderInstaller(instanceDir: meta.dir, onProgress: onProgress)
            if let result = try await installer.install(loader, mcVersion: mcVersion,
                                                        loaderVersion: loaderVersion) {
                meta.loaderType = loader.rawValue
                meta.loaderVersion = loaderVersion
                meta.mainClass = result.mainClass
                meta.extraJars = result.extraJars
                meta.gameJvmArgs = result.gameJvmArgs
                meta.gameArgs = result.gameArgs
            }
        }

        // 3) 인덱스가 지정한 외부 파일들 — 모드 200개짜리 팩을 하나씩 받으면 설치가 몇 분씩 걸린다.
        let files = ((index["files"] as? [[String: Any]]) ?? []).compactMap {
            f -> (path: String, downloads: [String])? in
            guard let path = f["path"] as? String,
                  let downloads = f["downloads"] as? [String], !downloads.isEmpty,
                  !path.contains("..")
            else { return nil }
            return (path, downloads)
        }
        await downloadAll(files.map { ($0.downloads, meta.dir.appending(path: $0.path), $0.path) })

        // 4) overrides/ (설정 파일·리소스팩 등 팩 제작자가 직접 넣은 것)
        _ = try? Zip.unzip(archive, to: meta.dir, strip: "overrides/")
        _ = try? Zip.unzip(archive, to: meta.dir, strip: "client-overrides/")
        try? FileManager.default.removeItem(at: archive)

        // 5) Sodium 이 들어있으면 Podium 을 끼워넣는다 (아래 설명 참고)
        await Self.installPodiumIfSodium(instanceDir: meta.dir, mcVersion: mcVersion,
                                         loader: loader, onProgress: onProgress)

        // 6) 아이콘 (목록에서 팩 로고를 보여주기 위해)
        if let logo = item.logoURL {
            _ = try? await HTTP.download(logo.absoluteString, to: meta.dir.appending(path: "icon.png"))
            meta.iconPath = "icon.png"
        }

        InstanceStore.shared.save(meta)
        onProgress(DownloadProgress(phase: .done))
        return meta
    }

    // MARK: - CurseForge 모드팩

    /// CurseForge `.zip` 모드팩을 새 인스턴스로 설치한다.
    ///
    /// mrpack 과 달리 `manifest.json` 의 `files[]` 에는 `{projectID, fileID}` 만 있다.
    /// 실제 파일 이름·URL 과 "이게 모드인지 리소스팩인지"(classId)는 CurseForge API 로
    /// 따로 조회해야 한다. 그래서 API 키가 없으면 설치 자체가 불가능하다.
    private func installCurseForgePack(
        _ item: ContentItem, archive: URL, versions: [VersionEntry]
    ) async throws -> InstanceMeta {
        guard let data = try Zip.extract("manifest.json", from: archive),
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let minecraft = manifest["minecraft"] as? [String: Any],
              let mcVersion = minecraft["version"] as? String
        else { throw LoaderInstallError.missingField("modrinth.index.json / manifest.json") }

        guard CurseForgeAPI.isConfigured else {
            throw LoaderInstallError.unsupported(
                String(localized: "CurseForge 모드팩은 API 키가 있어야 파일을 받을 수 있습니다."))
        }

        // "fabric-0.16.9" 처럼 로더와 버전이 한 문자열에 붙어 있다.
        let loaders = (minecraft["modLoaders"] as? [[String: Any]]) ?? []
        let primary = loaders.first { $0["primary"] as? Bool == true } ?? loaders.first
        let (loader, loaderVersion) = Self.loaderFrom(curseForgeId: primary?["id"] as? String ?? "")

        let packName = (manifest["name"] as? String) ?? item.name
        let id = InstanceStore.withToken(InstanceStore.modpackId(packName), InstanceStore.newToken())
        var meta = InstanceMeta(id: id, name: packName, type: .modpack, mcVersion: mcVersion)
        meta.sourceModId = Int(item.id)
        Paths.ensureDir(meta.dir)

        // 1) 바닐라 베이스
        guard let entry = versions.first(where: { $0.id == mcVersion }) else {
            throw LoaderInstallError.unsupported("모드팩이 요구하는 MC \(mcVersion) 을 목록에서 못 찾았습니다.")
        }
        let prepared = try await MinecraftDownloader(
            instanceDir: meta.dir, versionEntry: entry, onProgress: onProgress
        ).prepare()
        meta.assetIndexId = prepared.assetIndexId
        meta.mainClass = prepared.mainClass

        // 2) 로더
        if let loader, let loaderVersion {
            let installer = LoaderInstaller(instanceDir: meta.dir, onProgress: onProgress)
            if let result = try await installer.install(loader, mcVersion: mcVersion,
                                                        loaderVersion: loaderVersion) {
                meta.loaderType = loader.rawValue
                meta.loaderVersion = loaderVersion
                meta.mainClass = result.mainClass
                meta.extraJars = result.extraJars
                meta.gameJvmArgs = result.gameJvmArgs
                meta.gameArgs = result.gameArgs
            }
        }

        // 3) manifest 의 파일들 — 이름/URL/종류를 API 로 한 번에 조회한 뒤 받는다.
        let entries = ((manifest["files"] as? [[String: Any]]) ?? []).filter {
            ($0["required"] as? Bool) ?? true
        }
        let fileIds = entries.compactMap { $0["fileID"] as? Int }
        let projectIds = Array(Set(entries.compactMap { $0["projectID"] as? Int }))
        let infos = await CurseForgeAPI.fileInfos(fileIds)
        let classes = await CurseForgeAPI.classIds(projectIds)

        let targets = entries.compactMap { e -> ([String], URL, String)? in
            guard let fileId = e["fileID"] as? Int, let info = infos[fileId],
                  let link = info.url else { return nil }
            // 12 = 리소스팩, 6552 = 셰이더팩. 나머지(6 = 모드 포함)는 mods/ 가 안전한 기본값이다.
            let folder: String
            switch classes[e["projectID"] as? Int ?? 0] {
            case 12:   folder = "resourcepacks"
            case 6552: folder = "shaderpacks"
            default:   folder = "mods"
            }
            return ([link], meta.dir.appending(path: "\(folder)/\(info.fileName)"), info.fileName)
        }
        await downloadAll(targets)

        // 4) overrides (팩 제작자가 직접 넣은 설정·리소스)
        let overrides = (manifest["overrides"] as? String) ?? "overrides"
        _ = try? Zip.unzip(archive, to: meta.dir, strip: "\(overrides)/")
        try? FileManager.default.removeItem(at: archive)

        // 5) Sodium 이 있으면 Podium 을 끼워넣는다
        await Self.installPodiumIfSodium(instanceDir: meta.dir, mcVersion: mcVersion,
                                         loader: loader, onProgress: onProgress)

        if let logo = item.logoURL {
            _ = try? await HTTP.download(logo.absoluteString, to: meta.dir.appending(path: "icon.png"))
            meta.iconPath = "icon.png"
        }

        InstanceStore.shared.save(meta)
        onProgress(DownloadProgress(phase: .done))
        return meta
    }

    /// 모드팩 파일들을 12개씩 겹쳐 받는다. 후보 URL 목록 · 저장 위치 · 진행 표시용 이름.
    private func downloadAll(_ targets: [([String], URL, String)]) async {
        let total = targets.count
        let done = Counter()
        let onProgress = self.onProgress
        await Parallel.forEach(targets, limit: 12) { urls, dest, name in
            await HTTP.downloadFirst(urls, to: dest)
            let n = await done.increment()
            onProgress(DownloadProgress(phase: .installingLoader, current: n,
                                        total: total, fileName: name))
        }
    }

    /// "fabric-0.16.9" → (.fabric, "0.16.9")
    private static func loaderFrom(curseForgeId id: String) -> (ModLoader?, String?) {
        for loader in [ModLoader.neoforge, .fabric, .quilt, .forge] {
            let prefix = loader.rawValue + "-"
            if id.hasPrefix(prefix) { return (loader, String(id.dropFirst(prefix.count))) }
        }
        return (nil, nil)
    }

    // MARK: - Podium 보강

    /// Modrinth 의 Podium 프로젝트. CurseForge 쪽 "Podium (Pojav x Sodium)" 과 같은 모드다.
    /// (안드로이드판은 CurseForge 를 쓰지만 iOS 는 CF API 키가 없을 수 있어 Modrinth 로 받는다)
    private static let podiumProject = "podium"

    /// mods/ 에 Sodium 본체가 있으면 Podium 을 자동으로 끼워넣는다.
    ///
    /// Sodium 은 PojavLauncher 계열 환경을 감지하면 **스스로 실행을 거부**한다.
    /// Podium 이 그 차단을 무력화하는 호환 패치라, Sodium 을 쓰는 모드팩은 이게 없으면
    /// 아예 켜지지 않는다. (안드로이드 FlameLauncher 의 installPodiumIfSodiumInModpack 과 같은 규칙)
    ///
    /// 트리거 조건:
    ///  - 로더가 Fabric 또는 NeoForge (Podium 은 Forge/바닐라 미지원)
    ///  - mods/ 에 **Sodium 본체** jar 가 있을 것
    ///    — Sodium Extra / Reese's Sodium Options / Indium 같은 부가 모드는 제외한다
    ///  - 이미 podium*.jar 가 있으면 건너뛴다(팩이 이미 포함한 경우)
    ///
    /// 빌드 선택은 mc+로더 정확 매칭 → 로더만 매칭 → 최신 순으로 폴백한다.
    /// Podium 은 호환성 패치라 mc 버전을 정확히 안 맞춰도 도는 경우가 대부분이다.
    static func installPodiumIfSodium(
        instanceDir: URL, mcVersion: String, loader: ModLoader?,
        onProgress: @Sendable (DownloadProgress) -> Void
    ) async {
        guard let loader, loader == .fabric || loader == .neoforge else { return }

        let modsDir = instanceDir.appending(path: "mods")
        let jars = (try? FileManager.default.contentsOfDirectory(atPath: modsDir.path))?
            .filter { $0.hasSuffix(".jar") } ?? []
        guard !jars.isEmpty else { return }

        // 부가 모드가 아니라 **본체**일 때만 반응한다.
        let sodiumNames: Set<String> = ["sodium", "sodium-fabric", "sodium-neoforge", "embeddium"]
        guard jars.contains(where: { sodiumNames.contains(modFilePrefix($0).lowercased()) }) else { return }
        guard !jars.contains(where: { $0.lowercased().hasPrefix("podium") }) else { return }

        let loaderId = loader.rawValue
        // ?? 는 autoclosure 라 await 를 못 넣는다 — 순서대로 폴백한다.
        var picked = await podiumFile(mcVersion: mcVersion, loader: loaderId)
        if picked == nil { picked = await podiumFile(mcVersion: nil, loader: loaderId) }
        if picked == nil { picked = await podiumFile(mcVersion: nil, loader: nil) }
        guard let picked else { return }

        onProgress(DownloadProgress(phase: .installingLoader, fileName: picked.name))
        Paths.ensureDir(modsDir)
        _ = try? await HTTP.download(picked.url, to: modsDir.appending(path: picked.name))
    }

    /// Modrinth 에서 조건에 맞는 Podium 빌드 하나를 고른다(최신이 먼저 온다).
    private static func podiumFile(mcVersion: String?, loader: String?) async -> (name: String, url: String)? {
        var comps = URLComponents(string: "https://api.modrinth.com/v2/project/\(podiumProject)/version")
        var items: [URLQueryItem] = []
        if let loader { items.append(.init(name: "loaders", value: "[\"\(loader)\"]")) }
        if let mcVersion { items.append(.init(name: "game_versions", value: "[\"\(mcVersion)\"]")) }
        comps?.queryItems = items.isEmpty ? nil : items
        guard let url = comps?.url,
              let data = try? await HTTP.data(url),
              let versions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        for version in versions {
            guard let files = version["files"] as? [[String: Any]] else { continue }
            let file = files.first { $0["primary"] as? Bool == true } ?? files.first
            if let name = file?["filename"] as? String, let link = file?["url"] as? String {
                return (name, link)
            }
        }
        return nil
    }

    /// 파일 이름에서 버전 앞부분(모드 이름)만 잘라낸다.
    /// "sodium-fabric-0.8.12+mc1.21.1.jar" → "sodium-fabric"
    /// "sodium-fabric-mc1.20.1-0.5.0.jar"  → "sodium-fabric" (MC 버전이 **중간**에 오던 옛 배포본)
    /// "reeses-sodium-options-fabric-2.2.3.jar" → "reeses-sodium-options-fabric" (본체가 아니라 제외된다)
    ///
    /// ⚠️ 가운데 `mc1.20.1` 토큰을 안 끊으면 prefix 가 "sodium-fabric-mc1.20.1" 이 돼서 Sodium
    ///    본체로 인식되지 않는다 → Podium 이 조용히 안 깔리고, Sodium 은 Pojav 계열 환경에서
    ///    스스로 실행을 거부하므로 게임이 아예 안 켜진다(0.5.3 이전 배포본 30개가 이 형태다).
    static func modFilePrefix(_ fileName: String) -> String {
        let stem = fileName.hasSuffix(".jar") ? String(fileName.dropLast(4)) : fileName
        var parts: [Substring] = []
        for piece in stem.split(whereSeparator: { $0 == "-" || $0 == "_" }) {
            if piece.first?.isNumber == true { break }
            // "mc1.20.1" 같은 버전 토큰도 숫자와 같게 취급한다. "mcw-doors" 처럼 mc 로 시작만
            // 하는 이름은 그대로 둔다 — 바로 뒤가 숫자일 때만 버전으로 본다.
            if piece.count > 2, piece.hasPrefix("mc") || piece.hasPrefix("MC"),
               piece.dropFirst(2).first?.isNumber == true { break }
            parts.append(piece)
        }
        return parts.isEmpty ? stem : parts.joined(separator: "-")
    }

    /// dependencies 맵에서 로더 종류/버전을 뽑는다.
    private static func loaderFrom(dependencies: [String: String]) -> (ModLoader?, String?) {
        if let v = dependencies["fabric-loader"] { return (.fabric, v) }
        if let v = dependencies["quilt-loader"]  { return (.quilt, v) }
        if let v = dependencies["forge"]         { return (.forge, v) }
        if let v = dependencies["neoforge"]      { return (.neoforge, v) }
        return (nil, nil)
    }

    // MARK: - 사용자가 파일 앱에서 직접 넣은 파일

    /// "파일에서 가져오기" — 공유 시트/파일 앱으로 받은 로컬 파일을 알맞은 곳에 넣는다.
    /// 안드로이드 `ShareImportActivity` 대응.
    func importLocal(_ url: URL, into meta: InstanceMeta) throws -> String {
        let name = url.lastPathComponent
        let type: ContentType
        switch url.pathExtension.lowercased() {
        case "jar":     type = .mod
        case "mrpack":  type = .modpack
        case "zip":
            // .zip 은 리소스팩·셰이더팩·맵 셋 다 될 수 있다 — 안을 열어서 가른다.
            //   맵     → level.dat
            //   셰이더 → shaders/ 아래 .fsh/.vsh/shaders.properties
            let paths = (try? Zip.entries(of: Data(contentsOf: url)))?.map(\.path) ?? []
            if paths.contains(where: { $0.hasSuffix("level.dat") }) {
                type = .world
            } else if paths.contains(where: { $0.contains("shaders/") }) {
                type = .shader
            } else {
                type = .resourcepack
            }
        default:
            throw LoaderInstallError.unsupported(String(localized: "지원하지 않는 파일 형식: .\(url.pathExtension)"))
        }

        let folder = meta.dir.appending(path: type.installFolder)
        Paths.ensureDir(folder)

        if type == .world {
            try Zip.unzip(url, to: folder)
        } else {
            let dest = folder.appending(path: name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
        }
        return String(localized: "\(type.label)(으)로 가져왔습니다: \(name)")
    }
}
