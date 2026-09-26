import Foundation

struct LoaderInstallResult {
    var mainClass: String
    /// 인스턴스 디렉터리 기준 **상대** 경로. (절대경로는 앱 컨테이너가 바뀌면 깨진다)
    var extraJars: [String]
    var gameJvmArgs: [String] = []
    var gameArgs: [String] = []
}

enum LoaderInstallError: LocalizedError {
    case missingField(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .missingField(let f): return "\(f) 누락"
        case .unsupported(let m):  return m
        }
    }
}

/// Fabric/Quilt 로더를 `<instanceDir>/libraries/` 아래에 머지 설치한다.
/// 반드시 바닐라 다운로드를 먼저 끝낸 같은 인스턴스 디렉터리에서 호출할 것.
///
/// 안드로이드는 FabricInstaller / QuiltInstaller 두 파일이 다운로드 폴백 순서만 다르고
/// 나머지가 완전히 같은 복붙이었다 — 여기서는 폴백 저장소 목록만 파라미터로 받는다.
struct LoaderInstaller {
    let instanceDir: URL
    let onProgress: @Sendable (DownloadProgress) -> Void

    func installFabricLike(
        _ loader: ModLoader, mcVersion: String, loaderVersion: String
    ) async throws -> LoaderInstallResult {
        onProgress(DownloadProgress(phase: .installingLoader,
                                    fileName: String(localized: "\(loader.displayName) 프로필")))

        let raw = try await LoaderAPI.loaderProfile(loader, mcVersion: mcVersion,
                                                   loaderVersion: loaderVersion)
        // 프로필 원본도 인스턴스에 남긴다(디버그·재설치용) — 안드로이드와 동일.
        try? raw.write(to: instanceDir.appending(path: "\(loader.rawValue)-profile.json"))

        guard let profile = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let mainClass = profile["mainClass"] as? String
        else { throw LoaderInstallError.missingField("mainClass") }

        guard let libs = profile["libraries"] as? [[String: Any]] else {
            throw LoaderInstallError.missingField("libraries")
        }

        let mirrors = loader == .quilt
            ? ["https://maven.quiltmc.org/repository/release/",
               "https://maven.fabricmc.net/",
               "https://libraries.minecraft.net/"]
            : ["https://maven.fabricmc.net/",
               "https://libraries.minecraft.net/"]

        var jars: [String] = []
        for (i, lib) in libs.enumerated() {
            guard let name = lib["name"] as? String else { continue }
            onProgress(DownloadProgress(phase: .installingLoader, current: i + 1,
                                        total: libs.count, fileName: name))

            let path = Maven.path(name)
            let dest = instanceDir.appending(path: "libraries/\(path)")
            var candidates: [String] = []
            if let base = lib["url"] as? String {
                candidates.append(base.hasSuffix("/") ? base + path : "\(base)/\(path)")
            }
            candidates += mirrors.map { $0 + path }

            await HTTP.downloadFirst(candidates, to: dest)
            if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int,
               size > 0 {
                jars.append("libraries/\(path)")
            }
        }

        // Mojang 스타일 conditional 객체는 무시 — 단순 문자열 인자만 채택한다.
        let arguments = profile["arguments"] as? [String: Any]
        let jvmArgs = (arguments?["jvm"] as? [Any])?.compactMap { $0 as? String } ?? []
        let gameArgs = (arguments?["game"] as? [Any])?.compactMap { $0 as? String } ?? []

        return LoaderInstallResult(mainClass: mainClass, extraJars: jars,
                                   gameJvmArgs: jvmArgs, gameArgs: gameArgs)
    }

    /// Forge / NeoForge.
    ///
    /// ⚠️ 1.13+ Forge 는 설치 과정에서 **installer 안의 프로세서(JAR)를 실제로 실행**해
    ///    클라이언트 JAR 을 패치해야 한다(바이너리 패치·서명 제거·SRG 매핑).
    ///    iOS 는 프로세스를 fork 할 수 없어 설치 전용 JVM 을 못 띄우므로, 실행 계획만
    ///    만들어 두고 **게임을 띄우는 그 JVM 이 마인크래프트보다 먼저** 돌린다.
    func installForgeLike(
        _ loader: ModLoader, mcVersion: String, loaderVersion: String
    ) async throws -> LoaderInstallResult {
        let installerURL = loader == .neoforge
            ? LoaderAPI.neoForgeInstallerURL(loaderVersion)
            : LoaderAPI.forgeInstallerURL(mcVersion: mcVersion, forgeVersion: loaderVersion)

        onProgress(DownloadProgress(phase: .installingLoader,
                                    fileName: "\(loader.displayName) installer"))
        let dest = instanceDir.appending(path: "installer/\(loader.rawValue)-\(loaderVersion)-installer.jar")
        try await HTTP.download(installerURL, to: dest)

        return try await ForgeProcessorRunner(instanceDir: instanceDir, installerJar: dest,
                                              onProgress: onProgress)
            .run(loader: loader, mcVersion: mcVersion, loaderVersion: loaderVersion)
    }

    func install(_ loader: ModLoader, mcVersion: String, loaderVersion: String) async throws -> LoaderInstallResult? {
        switch loader {
        case .vanilla:
            return nil
        case .fabric, .quilt:
            return try await installFabricLike(loader, mcVersion: mcVersion, loaderVersion: loaderVersion)
        case .forge, .neoforge:
            return try await installForgeLike(loader, mcVersion: mcVersion, loaderVersion: loaderVersion)
        }
    }
}

/// Forge installer 의 `install_profile.json` 을 읽어 프로세서를 순서대로 돌리는 실행기.
/// 실제 실행은 `JavaRuntime` 이 담당하고, 이 타입은 인자 조립만 한다.
struct ForgeProcessorRunner {
    let instanceDir: URL
    let installerJar: URL
    let onProgress: @Sendable (DownloadProgress) -> Void

    func run(loader: ModLoader, mcVersion: String, loaderVersion: String) async throws -> LoaderInstallResult {
        let extracted = instanceDir.appending(path: "installer/extracted")
        try Zip.unzip(installerJar, to: extracted)

        // ⚠️ 1.12.2 이하(레거시) 설치기에는 **version.json 이 없다.** 같은 내용이
        //    install_profile.json 의 `versionInfo` 에 통째로 들어 있고, 유니버설 jar 도
        //    메이븐이 아니라 설치기 안에 들어 있다. (안드로이드는 예전부터 양쪽을 다 읽는다)
        let installProfile = extracted.appending(path: "install_profile.json")
        let installRoot = (try? Data(contentsOf: installProfile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil

        let profile: [String: Any]
        if let data = try? Data(contentsOf: extracted.appending(path: "version.json")),
           let modern = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            profile = modern
        } else if let legacy = installRoot?["versionInfo"] as? [String: Any] {
            profile = legacy
        } else {
            throw LoaderInstallError.missingField("version.json / versionInfo")
        }
        guard let mainClass = profile["mainClass"] as? String
        else { throw LoaderInstallError.missingField("mainClass") }

        // 라이브러리 내려받기 (Forge 는 저장소가 네 곳에 흩어져 있다)
        var jars: [String] = []
        let libs = (profile["libraries"] as? [[String: Any]]) ?? []
        for (i, lib) in libs.enumerated() {
            guard let name = lib["name"] as? String else { continue }
            onProgress(DownloadProgress(phase: .installingLoader, current: i + 1,
                                        total: libs.count, fileName: name))
            let path = Maven.path(name)
            let dest = instanceDir.appending(path: "libraries/\(path)")
            await HTTP.downloadFirst([
                "https://maven.minecraftforge.net/\(path)",
                "https://libraries.minecraft.net/\(path)",
                "https://maven.neoforged.net/releases/\(path)",
                "https://maven.fabricmc.net/\(path)",
            ], to: dest)
            if FileManager.default.fileExists(atPath: dest.path) {
                jars.append("libraries/\(path)")
            }
        }

        // 레거시: 유니버설 jar 은 메이븐에 그 이름으로 없다(있는 건 -universal 분류자뿐).
        // 설치기 안에 들어 있으니 꺼내서 라이브러리 자리에 놓고 **클래스패스 맨 앞**에 둔다.
        if let install = installRoot?["install"] as? [String: Any],
           let coord = install["path"] as? String, let file = install["filePath"] as? String {
            let path = Maven.path(coord)
            let dest = instanceDir.appending(path: "libraries/\(path)")
            let src = extracted.appending(path: file)
            if FileManager.default.fileExists(atPath: src.path) {
                Paths.ensureDir(dest.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: src, to: dest)
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                jars.removeAll { $0 == "libraries/\(path)" }
                jars.insert("libraries/\(path)", at: 0)
            }
        }

        // 프로세서 체인 — 있으면 실행 계획을 만들어 둔다.
        // iOS 는 설치 전용 JVM 을 못 띄우므로, 게임을 띄우는 그 JVM 이 마인크래프트보다
        // 먼저 이 계획을 실행한다(`kr.co.donghyun.flame.Bootstrap`).
        if let installData = installRoot,
           let processors = installData["processors"] as? [[String: Any]], !processors.isEmpty {
            let vanillaJars = Self.vanillaLibraryPaths(instanceDir: instanceDir, mcVersion: mcVersion)
            try await ForgeInstallPlanner(
                instanceDir: instanceDir, installerJar: installerJar,
                extracted: extracted, mcVersion: mcVersion, onProgress: onProgress
            ).write(profile: installData, processors: processors,
                    gameJars: Set(jars).union(vanillaJars))
        }

        let args = profile["arguments"] as? [String: Any]
        // 레거시는 인자가 한 줄짜리 `minecraftArguments` 다(--tweakClass 가 여기 들어 있다).
        var gameArgs = (args?["game"] as? [Any])?.compactMap { $0 as? String } ?? []
        if gameArgs.isEmpty, let legacy = profile["minecraftArguments"] as? String {
            gameArgs = legacy.split(separator: " ").map(String.init)
        }
        return LoaderInstallResult(
            mainClass: mainClass,
            extraJars: jars,
            gameJvmArgs: (args?["jvm"] as? [Any])?.compactMap { $0 as? String } ?? [],
            gameArgs: gameArgs
        )
    }

    /// 바닐라 version.json 이 요구하는 라이브러리(인스턴스 기준 상대경로).
    ///
    /// Forge·NeoForge 의 프로파일은 바닐라를 `inheritsFrom` 으로 상속받기 때문에
    /// 공통 라이브러리(gson·guava·log4j …)를 자기 목록에 담지 않는다. "설치 전용"을
    /// 가려낼 때 이 목록이 빠지면 게임이 실제로 쓰는 라이브러리가 제외된다.
    static func vanillaLibraryPaths(instanceDir: URL, mcVersion: String) -> Set<String> {
        let file = instanceDir.appending(path: "versions/\(mcVersion)/\(mcVersion).json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let libraries = root["libraries"] as? [[String: Any]]
        else { return [] }
        return Set(libraries.compactMap { lib in
            (lib["name"] as? String).map { "libraries/\(Maven.path($0))" }
        })
    }

}
