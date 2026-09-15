import Foundation

/// 설치된 JRE 하나. `Documents/runtimes/<이름>/` 아래에 bin/, lib/ 가 있어야 한다.
///
/// PojavLauncher iOS 와 같은 배치를 쓴다 — 그쪽 JRE 패키지를 그대로 풀어 넣을 수 있다.
struct JavaInstall: Identifiable, Hashable {
    let name: String
    let home: URL
    /// 8, 17, 21 …
    let majorVersion: Int

    var id: String { name }

    var isUsable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: home.appending(path: "lib/libjli.dylib").path)
            || fm.fileExists(atPath: home.appending(path: "lib/jli/libjli.dylib").path)
    }
}

enum JavaInstallStore {
    /// 사용자가 직접 넣는 곳(파일 앱에서 보인다). 여기 있는 게 번들보다 우선한다.
    static var runtimesDir: URL { Paths.external.appending(path: "runtimes") }

    /// 앱과 함께 배포되는 JRE. `Scripts/fetch-runtime.sh` 가 채우고 빌드가 번들에 넣는다.
    static var bundledRuntimesDir: URL {
        Bundle.main.bundleURL.appending(path: "java_runtimes")
    }

    /// 설치된 JRE 목록. 이름에서 메이저 버전을 뽑는다(예: "java-17-openjdk" → 17).
    ///
    /// 같은 메이저 버전이 양쪽에 있으면 사용자가 넣은 쪽을 쓴다 — 번들 JRE 가 문제일 때
    /// 앱을 다시 빌드하지 않고 갈아끼울 수 있어야 한다.
    static func installed() -> [JavaInstall] {
        Paths.ensureDir(runtimesDir)
        let user = installed(in: runtimesDir)
        let bundled = installed(in: bundledRuntimesDir)
        let userVersions = Set(user.map(\.majorVersion))
        return (user + bundled.filter { !userVersions.contains($0.majorVersion) })
            .sorted { $0.majorVersion < $1.majorVersion }
    }

    static func installed(in root: URL) -> [JavaInstall] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        return dirs.compactMap { dir -> JavaInstall? in
            let install = JavaInstall(name: dir.lastPathComponent, home: dir,
                                      majorVersion: majorVersion(in: dir))
            return install.isUsable ? install : nil
        }
        .sorted { $0.majorVersion < $1.majorVersion }
    }

    /// 이 버전을 돌리기에 맞는 JRE 를 고른다.
    /// 최소 요구 버전 이상 중 **가장 낮은** 것 — 필요 이상으로 높은 JRE 를 쓰면
    /// 구버전 마인크래프트가 모듈 캡슐화에 걸려 죽는다.
    static func select(minVersion: Int) -> JavaInstall? {
        select(minVersion: minVersion, from: installed())
    }

    static func select(minVersion: Int, from all: [JavaInstall]) -> JavaInstall? {
        // ⚠️ 요구 버전에 못 미치면 **아무것도 돌려주지 않는다.**
        //    예전에는 `?? all.last` 로 가장 높은 JRE 를 떠넘겼다. 그러면 게임은 뜨는 척하다
        //    자바가 클래스를 못 읽어 죽고, 사용자에게는 이런 것만 남는다:
        //      "UnsupportedClassVersionError: … class file version 69.0,
        //       this version of the Java Runtime only recognizes class file versions up to 65.0"
        //    (마인크래프트 26.2 가 Java 25 를 요구하는데 21 로 띄운 실제 사례다)
        //    호출자가 LaunchError.noRuntime 으로 "Java N 이 필요합니다"를 띄우게 둔다.
        all.first { $0.majorVersion >= minVersion }
    }

    /// `release` 파일이나 폴더 이름에서 메이저 버전을 읽는다.
    private static func majorVersion(in dir: URL) -> Int {
        if let release = try? String(contentsOf: dir.appending(path: "release"), encoding: .utf8),
           let line = release.split(separator: "\n").first(where: { $0.hasPrefix("JAVA_VERSION=") }) {
            let value = line.replacingOccurrences(of: "JAVA_VERSION=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            // "1.8.0_312" → 8, "17.0.9" → 17
            let parts = value.split(separator: ".")
            if parts.first == "1", parts.count > 1 { return Int(parts[1]) ?? 8 }
            if let first = parts.first, let n = Int(first) { return n }
        }
        // 폴더 이름 폴백: 처음 나오는 숫자 뭉치
        let digits = dir.lastPathComponent.split(whereSeparator: { !$0.isNumber })
        return digits.compactMap { Int($0) }.first ?? 8
    }
}
