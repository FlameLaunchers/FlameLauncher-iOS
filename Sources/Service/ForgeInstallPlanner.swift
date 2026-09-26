import Foundation

/// Forge / NeoForge 의 `install_profile.json` 을 **실행 계획**으로 바꾼다.
///
/// 데스크톱 런처는 프로세서마다 새 JVM 을 띄우지만 iOS 는 프로세스를 만들 수 없다.
/// 그래서 여기서 자리표시자를 전부 풀어 계획 파일 하나로 만들고, 실행은
/// 게임 JVM 이 마인크래프트보다 먼저 한다(`kr.co.donghyun.flame.Bootstrap`).
///
/// 계획 형식은 단순하다 — 자바 쪽이 의존성 없이 읽을 수 있게 일부러 얕게 뒀다.
/// 경로는 **인스턴스 폴더 기준 상대경로**다:
/// ```json
/// { "steps": [ { "jar": "libraries/...", "classpath": ["libraries/..."], "args": ["..."] } ] }
/// ```
struct ForgeInstallPlanner {
    /// 계획 파일 이름. 있으면 게임 시작 전에 실행한다.
    static let planFileName = "forge_plan.json"

    /// 프로세서를 이미 돌렸다는 표시. 자바 쪽(`Bootstrap`)이 만들고 여기서 지운다.
    ///
    /// 계획 파일을 지워서 표시하면 안 된다 — 실행할 때마다 클래스패스를 만들 때
    /// 설치 전용 라이브러리(`installOnlyPaths`)와 산출물(`outputPaths`)을 거기서 읽는다.
    static let doneFileName = "forge_plan.done"

    /// 예전 계획에 박힌 **절대경로**를 인스턴스 기준 상대경로로 고친다.
    ///
    /// 앱을 다시 설치하면 데이터 컨테이너 UUID 가 바뀌어 절대경로가 통째로 깨진다.
    /// 새로 만드는 계획은 처음부터 상대경로지만, 이미 만들어둔 인스턴스는 스스로 낫게 한다.
    ///
    /// ⚠️ 원문 문자열을 뒤지면 안 된다 — JSONSerialization 이 `/` 를 `\/` 로 이스케이프해서
    ///    경로가 그대로 들어 있어도 검색이 빗나간다(실제로 그래서 한 번 놓쳤다).
    ///    반드시 파싱한 뒤 값 단위로 고친다.
    static func migrateIfNeeded(instanceDir: URL) {
        let file = instanceDir.appending(path: planFileName)
        guard let data = try? Data(contentsOf: file),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var steps = root["steps"] as? [[String: Any]]
        else { return }

        // ".../instances/<id>/" 뒤쪽만 남기면 그대로 상대경로가 된다.
        let marker = "/instances/\(instanceDir.lastPathComponent)/"
        func strip(_ value: String) -> String {
            guard let range = value.range(of: marker) else { return value }
            return String(value[range.upperBound...])
        }

        var changed = false
        for i in steps.indices {
            if let jar = steps[i]["jar"] as? String {
                let fixed = strip(jar)
                if fixed != jar { steps[i]["jar"] = fixed; changed = true }
            }
            for key in ["classpath", "args"] {
                guard let list = steps[i][key] as? [String] else { continue }
                let fixed = list.map(strip)
                if fixed != list { steps[i][key] = fixed; changed = true }
            }
        }
        guard changed else { return }

        root["steps"] = steps
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? out.write(to: file)
        }
    }

    let instanceDir: URL
    let installerJar: URL
    /// installer jar 를 풀어둔 폴더.
    let extracted: URL
    let mcVersion: String
    let onProgress: @Sendable (DownloadProgress) -> Void

    private var librariesDir: URL { instanceDir.appending(path: "libraries") }

    /// ⚠️ 계획에는 **절대경로를 넣지 않는다.**
    ///
    /// 앱을 다시 설치하면 데이터 컨테이너 UUID 가 바뀌어서 설치 때 적어둔 절대경로가
    /// 통째로 깨진다(실제로 NoSuchFileException 으로 죽었다).
    /// 인스턴스 폴더 기준 상대경로로 적고, 실행은 그 폴더를 CWD 로 잡은 뒤에 한다
    /// (`GameLauncher` 가 chdir, `-Duser.dir` 둘 다 인스턴스로 맞춰둔다).
    private func relative(_ url: URL) -> String { relative(url.path) }

    private func relative(_ path: String) -> String {
        let root = instanceDir.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    /// 계획 안의 "설치 전용" 목록 키. 게임 클래스패스에서 제외할 라이브러리들이다.
    static let installOnlyKey = "installOnly"

    /// 로더 자신의 코드가 든 jar(neoforge/forge universal·client). 설치 전용으로 볼 수 없다.
    static func isLoaderOwnJar(_ relativePath: String) -> Bool {
        relativePath.contains("/net/neoforged/neoforge/")
            || relativePath.contains("/net/minecraftforge/forge/")
    }

    /// 계획이 지정한 설치 전용 라이브러리(인스턴스 기준 상대경로).
    static func installOnlyPaths(instanceDir: URL) -> Set<String> {
        let file = instanceDir.appending(path: planFileName)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root[installOnlyKey] as? [String]
        else { return [] }
        return Set(list)
    }

    /// 프로세서가 **만들어 내는** 산출물(인스턴스 기준 상대경로).
    ///
    /// ⚠️ 게임 클래스패스에 넣으면 안 된다. version.json 의 라이브러리 목록에 없는 중간
    ///    파일인데 안에 `net.minecraft.**` 가 통째로 들어 있다. 클래스패스에 남기면
    ///    FML 이 만든 `minecraft` 모듈과 같은 패키지를 다른 모듈이 또 export 하게 되어
    ///    모듈 해석이 실패한다:
    ///
    ///      ResolutionException: Modules minecraft and neoforge export package
    ///        net.minecraft.server.players to module mixin_synthetic
    ///
    ///    FML 은 이것들을 `-DlibraryDirectory` 와 maven 좌표로 직접 찾으므로
    ///    클래스패스에서 빼도 문제가 없다(로그의 "production client provider" 경로).
    static func outputPaths(instanceDir: URL) -> Set<String> {
        let file = instanceDir.appending(path: planFileName)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = root["steps"] as? [[String: Any]]
        else { return [] }

        var out: Set<String> = []
        for step in steps {
            guard let args = step["args"] as? [String] else { continue }
            for (index, arg) in args.enumerated() where arg == "--output" || arg == "--out" {
                guard index + 1 < args.count else { continue }
                out.insert(args[index + 1])
            }
        }
        return out
    }

    /// - Parameter gameJars: version.json 이 요구하는 라이브러리(인스턴스 기준 상대경로).
    ///   여기에 없는 설치 라이브러리는 프로세서 전용이므로 게임 클래스패스에서 뺀다.
    func write(profile: [String: Any], processors: [[String: Any]],
               gameJars: Set<String>) async throws {
        // 예전 빌드가 `@확장자` 를 못 풀어 `...-mappings@tsrg.jar` 같은 이름으로 남긴 파일들.
        // 클래스패스가 libraries/ 아래 .jar 을 전부 모으므로 그대로 두면 Forge 가 죽는다.
        removeMisnamedArtifacts()

        // 1) 프로세서가 쓰는 라이브러리는 version.json 것과 **별개**다. 따로 받는다.
        // 1) 프로세서가 쓰는 라이브러리는 version.json 것과 **별개**다. 따로 받는다.
        let installed = try await downloadInstallLibraries(profile)

        // ⚠️ 그중 게임이 요구하지 않는 것은 **게임 클래스패스에 들어가면 안 된다.**
        //    설치 도구들은 같은 라이브러리의 다른 버전을 끌고 온다(jopt-simple, asm, srgutils …).
        //    Forge 는 모듈 경로를 쓰기 때문에 같은 패키지를 두 모듈이 export 하면 부팅이 막힌다:
        //      "Modules jopt.simple and joptsimple export package joptsimple"
        // ⚠️ 단, **로더 본체**는 예외다. NeoForge 26.x 는 neoforge-…-universal.jar 을 설치
        //    프로필로만 들고 오고 version.json 에는 올리지 않아서, 위 규칙대로면 게임
        //    클래스패스에서 빠진다. 그러면 FML 이 자기 클래스(NeoForgeMod)를 못 찾고
        //    엉뚱한 메시지로 죽는다:
        //      Couldn't find [net/neoforged/neoforge/common/NeoForgeMod.class, …]
        //      The patched Minecraft jar is missing. Please try to reinstall NeoForge.
        let installOnly = Set(installed.subtracting(gameJars).filter { !Self.isLoaderOwnJar($0) })

        // 2) data 값 풀기 — 자리표시자의 실제 값이 여기 들어 있다.
        let data = try resolveData(profile["data"] as? [String: Any] ?? [:])

        // 3) 프로세서별로 인자를 풀어 계획으로 만든다. 클라이언트에 필요한 것만.
        var steps: [[String: Any]] = []
        for processor in processors {
            if let sides = processor["sides"] as? [String], !sides.contains("client") { continue }
            guard let jarName = processor["jar"] as? String else { continue }

            let classpath = (processor["classpath"] as? [String] ?? []).map {
                relative(librariesDir.appending(path: Maven.path($0)))
            }
            let args = (processor["args"] as? [String] ?? []).map { resolve($0, data: data) }

            steps.append([
                "jar": relative(librariesDir.appending(path: Maven.path(jarName))),
                "classpath": classpath,
                "args": args,
            ])
        }

        let plan = try JSONSerialization.data(
            withJSONObject: ["steps": steps, Self.installOnlyKey: Array(installOnly).sorted()],
            options: [.prettyPrinted])
        try plan.write(to: instanceDir.appending(path: Self.planFileName))
        // 계획을 새로 썼으면 "이미 돌렸음" 표시를 지운다 — 새 계획은 다시 돌아야 한다.
        try? FileManager.default.removeItem(at: instanceDir.appending(path: Self.doneFileName))
    }

    /// 좌표를 잘못 풀어 만들어진 `...@ext.jar` 잔재를 지운다.
    private func removeMisnamedArtifacts() {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: librariesDir, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker
        where url.pathExtension == "jar" && url.lastPathComponent.contains("@") {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - 라이브러리

    /// - Returns: 받아둔(또는 이미 있던) 라이브러리들의 인스턴스 기준 상대경로.
    @discardableResult
    private func downloadInstallLibraries(_ profile: [String: Any]) async throws -> Set<String> {
        var paths: Set<String> = []
        let libs = (profile["libraries"] as? [[String: Any]]) ?? []
        for (i, lib) in libs.enumerated() {
            guard let name = lib["name"] as? String else { continue }
            let path = Maven.path(name)
            let dest = librariesDir.appending(path: path)
            paths.insert("libraries/\(path)")
            if FileManager.default.fileExists(atPath: dest.path) { continue }

            onProgress(DownloadProgress(phase: .installingLoader, current: i + 1,
                                        total: libs.count, fileName: name))

            // 프로필이 URL 을 직접 주면 그걸 먼저 쓰고, 없으면 아는 저장소를 훑는다.
            var candidates: [String] = []
            if let url = ((lib["downloads"] as? [String: Any])?["artifact"]
                            as? [String: Any])?["url"] as? String, !url.isEmpty {
                candidates.append(url)
            }
            candidates += [
                "https://maven.neoforged.net/releases/\(path)",
                "https://maven.minecraftforge.net/\(path)",
                "https://libraries.minecraft.net/\(path)",
                "https://maven.fabricmc.net/\(path)",
            ]
            await HTTP.downloadFirst(candidates, to: dest)
        }
        return paths
    }

    // MARK: - 자리표시자

    /// `data` 의 각 항목을 실제 경로/문자열로 바꾼다.
    ///
    /// 값의 형태는 세 가지다:
    ///  - `[group:artifact:version:classifier@ext]` → libraries 아래 경로
    ///  - `/installer/안의/경로`                     → installer jar 에서 꺼내 쓴다
    ///  - `'따옴표 문자열'`                           → 그대로(따옴표만 벗긴다)
    private func resolveData(_ raw: [String: Any]) throws -> [String: String] {
        var out: [String: String] = [:]

        // 프로세서가 늘 쓰는 내장 값들.
        out["SIDE"] = "client"
        out["ROOT"] = "."
        out["INSTALLER"] = relative(installerJar)
        out["MINECRAFT_JAR"] = relative(
            instanceDir.appending(path: "versions/\(mcVersion)/\(mcVersion).jar"))

        for (key, value) in raw {
            guard let client = (value as? [String: Any])?["client"] as? String else { continue }
            out[key] = try resolveDataValue(client, key: key)
        }
        return out
    }

    private func resolveDataValue(_ value: String, key: String) throws -> String {
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let coord = String(value.dropFirst().dropLast())
            return relative(librariesDir.appending(path: Maven.path(coord)))
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("/") {
            // installer jar 안의 파일 — 이미 풀어둔 폴더에서 꺼내 쓴다.
            let inside = extracted.appending(path: String(value.dropFirst()))
            guard FileManager.default.fileExists(atPath: inside.path) else {
                throw LoaderInstallError.missingField("installer 안에 \(value) 가 없습니다 (\(key))")
            }
            return relative(inside)
        }
        return value
    }

    /// 인자 하나를 푼다. `{KEY}` 는 data 값으로, `[maven]` 은 라이브러리 경로로 바꾼다.
    private func resolve(_ arg: String, data: [String: String]) -> String {
        if arg.hasPrefix("[") && arg.hasSuffix("]") {
            let coord = String(arg.dropFirst().dropLast())
            return relative(librariesDir.appending(path: Maven.path(coord)))
        }
        guard arg.contains("{") else { return arg }

        var out = ""
        var key = ""
        var inKey = false
        for ch in arg {
            switch (ch, inKey) {
            case ("{", false): inKey = true; key = ""
            case ("}", true):
                inKey = false
                // 모르는 키는 원문 그대로 둔다 — 조용히 빈 값으로 바꾸면 원인을 못 찾는다.
                out += data[key] ?? "{\(key)}"
            case (_, true): key.append(ch)
            case (_, false): out.append(ch)
            }
        }
        return out
    }
}
