import Foundation
import UIKit

/// 인스턴스 하나를 실제로 실행하기 위한 준비 일체 — JRE 선택, 클래스패스 조립,
/// JVM/게임 인자 구성, options.txt 동기화, 렌더러 환경변수.
///
/// 안드로이드 `MinecraftActivity.startMinecraft()` 의 순수 로직 부분에,
/// PojavLauncher iOS 의 `JavaLauncher.m` 이 하던 iOS 전용 처리를 합친 것이다.
/// 뷰/서피스 처리는 `GameView` 가 맡는다 — 그래서 인자 조립은 런타임 없이도 테스트할 수 있다.
struct GameLauncher {
    let meta: InstanceMeta
    let settings: JvmSettings
    let session: AuthSession?
    let screenSize: CGSize

    enum LaunchError: LocalizedError {
        case noRuntime(Int)

        var errorDescription: String? {
            switch self {
            case .noRuntime(let major):
                let have = JavaInstallStore.installed().map { String($0.majorVersion) }
                let list = have.isEmpty ? String(localized: "없음") : have.joined(separator: ", ")
                return "이 버전에는 Java \(major) 이상이 필요합니다. (설치된 JRE: \(list))\n"
                     + "Documents/runtimes/ 아래에 iOS용 OpenJDK \(major) 를 넣어주세요."
            }
        }
    }

    struct LaunchPlan {
        let javaHome: URL
        /// JLI_Launch 에 그대로 넘길 전체 인자. argv[0] 은 java 실행 파일 경로.
        let argv: [String]
        let env: [String: String]
        let renderer: Renderer
        let guiScale: Int
        let modCount: Int
    }

    /// 이 버전이 요구하는 LWJGL 이 3.4 이상인가.
    ///
    /// 마인크래프트 26.2 부터 LWJGL 3.4.1 을 쓰는데, 3.3.3 과 **섞을 수 없다** —
    /// 3.4 는 콜백 인프라(`Upcalls`, `ffi_get_closure_size`)가 새로 생겨서 자바와 네이티브가
    /// 같은 버전이어야 한다. 반대로 3.4.1 을 1.21.x 에 쓰면 Iris 가 부팅 중에 죽는다.
    ///
    /// 그래서 스택을 통째로 둘로 나눠 두고 여기서 고른다:
    ///   libs/    + Frameworks/      → 3.3.3 (기본, 1.21.x 이하 검증됨)
    ///   libs341/ + Frameworks341/   → 3.4.1 (26.2+)
    ///
    /// 판단 근거는 버전 JSON 의 라이브러리 목록이다 — 추측하지 않는다.
    static func needsLwjgl34(instanceDir: URL, mcVersion: String) -> Bool {
        let file = instanceDir.appending(path: "versions/\(mcVersion)/\(mcVersion).json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let libraries = root["libraries"] as? [[String: Any]]
        else { return false }

        for library in libraries {
            guard let name = library["name"] as? String,
                  name.hasPrefix("org.lwjgl:lwjgl:") else { continue }
            // "org.lwjgl:lwjgl:3.4.1" / "…:3.4.1:natives-macos"
            let parts = name.split(separator: ":")
            guard parts.count >= 3 else { continue }
            let version = parts[2].split(separator: ".").compactMap { Int($0) }
            guard version.count >= 2 else { continue }
            if version[0] > 3 || (version[0] == 3 && version[1] >= 4) { return true }
        }
        return false
    }

    /// 이 버전을 돌리는 데 필요한 JRE 메이저 버전.
    ///
    /// Mojang 이 version JSON 에 `javaVersion.majorVersion` 으로 정확히 알려준다.
    /// 버전 문자열 추측은 새 버전 체계("26.2")나 스냅샷에서 틀리므로 폴백으로만 쓴다.
    /// (1.21 을 17 로 띄웠다가 UnsupportedClassVersionError 로 죽은 적이 있다)
    static func requiredJavaMajor(instanceDir: URL, mcVersion: String) -> Int {
        let file = instanceDir.appending(path: "versions/\(mcVersion)/\(mcVersion).json")
        if let data = try? Data(contentsOf: file),
           let manifest = try? JSONDecoder().decode(VersionManifest.self, from: data),
           let major = manifest.javaVersion?.majorVersion {
            return major
        }
        return VersionRules.javaMajor(mcVersion)
    }

    /// 심볼릭 링크를 푼 실제 경로. (/var/mobile/… → /private/var/mobile/…)
    static func realPath(of url: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// 읽을 수 없게 만들어진 파일들을 되살린다.
    ///
    /// 예전 빌드의 `open` 후킹이 가변 인자를 잘못 읽어(arm64 에서 가변 인자는 스택,
    /// 고정 매개변수는 레지스터) `O_CREAT` 로 만드는 파일의 mode 에 쓰레기 값이
    /// 들어갔다. 그렇게 권한 000 으로 만들어진 파일은 다시 열 수 없어서
    /// 리소스팩·로그·스킨 캐시가 "Permission denied" 로 깨진다.
    /// 후킹은 고쳤지만 이미 만들어진 파일은 남으므로 한 번 훑어 고친다.
    /// FancyMenu 의 **macOS 전용** 창 아이콘 설정을 비운다.
    ///
    /// ⚠️ FancyMenu 는 `Minecraft.ON_OSX` 하나만 보고 macOS 분기를 탄다. 그 분기는
    ///    Rococoa(`ca.weblite.objc`) → JNA → AppKit 으로 내려가는데, iOS 에는 AppKit 도
    ///    iOS 용 libjnidispatch 도 없다. FancyMenu 가 그 호출을 try/catch 로 감싸 두긴
    ///    했지만 **Exception 만** 잡는다 — 실제로 오는 건 Error 라서 게임이 그대로 죽는다:
    ///
    ///      NoClassDefFoundError: Could not initialize class com.sun.jna.Native
    ///        at ca.weblite.objc.Runtime.<clinit>
    ///        at MacWindowUtil.setApplicationIconImage
    ///        at WindowHandler.updateCustomWindowIconMacOS
    ///
    ///    경로를 비우면 `getCustomWindowIconMacOS()` 가 null 이 되어 그 분기를 건너뛴다.
    ///    16/32 PNG 아이콘은 GLFW 경로(`updateCustomWindowIconWindowsLinux`)로 그대로 걸린다.
    ///
    /// 형식: `S:custom_window_icon_macos = '/config/...icns';`
    static func neutralizeMacOnlyModOptions(in dir: URL) {
        let file = dir.appending(path: "config/fancymenu/options.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }

        let key = "S:custom_window_icon_macos"
        var changed = false
        let fixed = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix(key), !line.hasSuffix("= '';") else { return String(line) }
            changed = true
            return "\(key) = '';"
        }
        guard changed else { return }

        try? fixed.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        print("[FlameLauncher] FancyMenu 의 macOS 전용 창 아이콘을 껐습니다 (iOS 에 AppKit 이 없습니다)")
    }

    /// Forge/NeoForge 1.17+ 의 **초기 로딩 창**(fmlearlydisplay)을 끈다.
    ///
    /// ⚠️ 이건 단순한 스플래시가 아니다. FML 이 Minecraft 보다 **먼저** GLFW 창과 GL
    ///    컨텍스트를 만들고 자기 렌더 스레드를 돌린 뒤 그대로 Minecraft 에 넘긴다.
    ///    모장 로고 구간(ForgeLoadingOverlay)은 그 early display 의 FBO 텍스처를
    ///    메인 창에 블릿하는 것이고, 창 close 콜백도 계속 FML 쪽이 쥐고 있다.
    ///
    ///    MobileGlues(ANGLE Metal / GLES 3.0) 위에서는 그 블릿이 검은 화면으로 끝나고,
    ///    뒤이어 close 콜백이 떠서 게임이 크래시 없이 조용히 exit(0) 한다:
    ///      [Render thread/INFO] [minecraft/Minecraft]: Stopping!
    ///    끄면 Minecraft 가 자기 창을 만들고 바닐라 LoadingOverlay 를 쓴다.
    ///
    /// ⚠️ `-Dfml.earlyprogresswindow=false` 는 1.17~1.18 시절 키라 52.x 는 쳐다보지도
    ///    않는다(로그에 `Loading ImmediateWindowProvider fmlearlywindow` 가 그대로 뜬다).
    ///    지금 스위치는 `config/fml.toml` 의 `earlyWindowControl` 하나뿐이다.
    static func disableForgeEarlyWindow(in dir: URL) {
        let libs = dir.appending(path: "libraries")
        let hasEarlyDisplay = ["net/minecraftforge", "net/neoforged"].contains {
            FileManager.default.fileExists(atPath: libs.appending(path: "\($0)/fmlearlydisplay").path)
        }
        guard hasEarlyDisplay else { return }

        let file = dir.appending(path: "config/fml.toml")
        let key = "earlyWindowControl"
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            // 첫 실행이라 아직 없다. 한 줄만 써 두면 night-config 의 spec correct 가
            // 나머지 기본값을 채워 넣는다.
            Paths.ensureDir(file.deletingLastPathComponent())
            try? "\(key) = false\n".write(to: file, atomically: true, encoding: .utf8)
            return
        }
        guard text.contains("\(key) = true") else { return }
        try? text.replacingOccurrences(of: "\(key) = true", with: "\(key) = false")
            .write(to: file, atomically: true, encoding: .utf8)
        print("[FlameLauncher] Forge 초기 로딩 창을 껐습니다 (MobileGlues 에서 검은 화면 뒤 조용히 종료됩니다)")
    }

    /// 확장된 JVM 인자에서 `-p` / `--module-path` 가 가리키는 jar 경로들.
    ///
    /// ⚠️ 같은 jar 이 모듈 경로와 클래스패스에 **동시에** 있으면 클래스가 두 로더에 생긴다.
    ///    NeoForge 의 `--add-opens java.base/java.util.jar=cpw.mods.securejarhandler` 는
    ///    **모듈** 쪽에만 열어 주므로, 클래스패스 사본이 이기면 실행 중 IllegalAccessError 가 난다.
    ///    데스크톱 런처들이 모듈 경로 jar 을 클래스패스에서 빼는 이유다.
    static func modulePathEntries(_ expandedArgs: [String]) -> Set<String> {
        var out: Set<String> = []
        var index = 0
        while index < expandedArgs.count {
            let arg = expandedArgs[index]
            if (arg == "-p" || arg == "--module-path"), index + 1 < expandedArgs.count {
                out.formUnion(expandedArgs[index + 1].split(separator: ":").map(String.init))
                index += 2
                continue
            }
            if let value = arg.split(separator: "=", maxSplits: 1).last,
               arg.hasPrefix("--module-path=") {
                out.formUnion(value.split(separator: ":").map(String.init))
            }
            index += 1
        }
        return out
    }

    /// 바닐라 LWJGL jar 을 게임 클래스패스에서 빼야 하는가.
    ///
    /// **전부 뺀다.** 패치된 병합 jar 이 LWJGL 전체를 대신하기 때문이다.
    ///
    /// ⚠️ 한때 "우리가 제공하지 않는 모듈은 남긴다"로 바꿨다가 NeoForge 가 깨졌다.
    ///    남겨 둔 `lwjgl-jemalloc-*.jar` 이 모듈 경로에 올라가는데, 그 모듈은
    ///    `requires org.lwjgl` 이고 코어 jar 은 우리가 뺀 상태라 해석이 실패한다:
    ///      FindException: Module org.lwjgl not found, required by org.lwjgl.jemalloc
    ///    부족한 모듈은 **병합 jar 에 넣어서** 해결해야지, 바닐라 jar 을 섞으면 안 된다
    ///    (마인크래프트 26.2 의 spvc 는 그렇게 libs341 쪽 병합본에 넣었다).
    static func shouldDropVanillaLwjgl(_ fileName: String) -> Bool {
        fileName.hasPrefix("lwjgl") && fileName.hasSuffix(".jar")
    }

    /// Forge/NeoForge 설치 프로세서의 **중간 산출물**인가.
    ///
    /// ⚠️ 이것들은 프로세서가 만들어 낸 중간 파일이라 version.json 의 라이브러리 목록에 없고,
    ///    설치 프로필의 `installOnly` 목록으로도 안 걸러진다(그건 **입력** 라이브러리만 안다).
    ///    그런데 안에 `net.minecraft.**` 가 통째로 들어 있어서, 클래스패스에 남으면
    ///    `client` 라는 자동 모듈이 되어 진짜 `minecraft` 모듈과 같은 패키지를 export 한다:
    ///
    ///      ResolutionException: Module minecraft contains package
    ///        net.minecraft.world.item.equipment.trim, module client exports … to minecraft
    ///
    ///    `-extra` 는 남긴다 — NeoForge 가 `-DignoreList=client-extra,…` 로 직접 건너뛰고,
    ///    데스크톱 설치본도 클래스패스에 그대로 두기 때문이다.
    static func isLoaderIntermediateJar(_ path: String) -> Bool {
        guard path.contains("/libraries/net/minecraft/") else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return ["-slim.jar", "-srg.jar", "-official.jar", "-data.jar", "-merged.jar"]
            .contains { name.hasSuffix($0) }
    }

    /// Maven 레이아웃에서 **버전을 뺀** 아티팩트 식별자.
    ///
    ///     .../libraries/org/ow2/asm/asm/9.8/asm-9.8.jar  →  .../libraries/org/ow2/asm/asm
    ///
    /// ⚠️ 모듈 경로 중복 제거를 경로 완전 일치로 하면 **버전이 다른 같은 모듈**을 놓친다.
    ///    BootstrapLauncher 는 그걸 그냥 넘기지 않는다:
    ///      "Module named org.objectweb.asm was already on the JVMs module path … but
    ///       class-path contains it at … asm-9.6.jar"
    ///    모듈 이름은 버전과 무관하므로 아티팩트 단위로 봐야 한다.
    static func artifactKey(_ jarPath: String) -> String {
        URL(fileURLWithPath: jarPath)
            .deletingLastPathComponent()   // 버전 디렉터리
            .deletingLastPathComponent()   // 아티팩트 디렉터리
            .path
    }

    /// 클래스패스 중복 판정용 — 아티팩트 + **분류자**. 버전만 다르면 같은 키다.
    ///
    ///     .../guava/failureaccess/1.0.1/failureaccess-1.0.1.jar    →  .../guava/failureaccess.jar
    ///     .../forge/1.21.4-54.1.14/forge-1.21.4-54.1.14-client.jar  →  .../minecraftforge/forge-client.jar
    ///
    /// ⚠️ 클래스패스는 `libraries/` 를 통째로 훑어 모으므로, 로더와 바닐라가 **다른 버전**을
    ///    받아 두면 둘 다 올라간다. 1.21.4 에서 Forge 와 Fabric 이 둘 다 이걸로 죽었다:
    ///      Forge 54.1.14  failureaccess 1.0.1 + 1.0.2 — 1.0.2 부터 모듈 이름이 바뀌어 둘 다 해석됨
    ///        ResolutionException: Modules com.google.common.util.concurrent.internal and
    ///        failureaccess export package com.google.common.util.concurrent.internal
    ///      Fabric 0.19.5  asm 9.10.1 + 9.6
    ///        IllegalStateException: duplicate ASM classes found on classpath
    ///    **먼저 온 것(로더)을 남긴다** — 공식 런처와 같고, Forge 도 guava 를 이미 그렇게 고른다.
    ///
    /// ⚠️ 분류자는 지킨다. `forge-…-client.jar` 와 `forge-…-universal.jar` 은 둘 다 필요하다.
    ///    Maven 배치가 아니면(앱 번들 libs/, versions/ 의 클라이언트 jar) 경로를 그대로 돌려준다.
    static func libraryKey(_ jarPath: String) -> String {
        let versionDir = URL(fileURLWithPath: jarPath).deletingLastPathComponent()
        let prefix = "\(versionDir.deletingLastPathComponent().lastPathComponent)-\(versionDir.lastPathComponent)"
        let name = URL(fileURLWithPath: jarPath).lastPathComponent
        guard name.hasPrefix(prefix) else { return jarPath }
        return artifactKey(jarPath) + name.dropFirst(prefix.count)
    }

    /// 로더(version.json)가 준 JVM 인자의 자리표시자를 실제 값으로 바꾼다.
    ///
    /// ⚠️ 예전에는 `filter { !$0.contains("${") }` 로 **자리표시자가 든 인자를 그냥 버렸다.**
    ///    그런데 NeoForge 의 목록은 플래그와 값이 **따로 떨어진 원소**다:
    ///
    ///        ["-p", "${library_directory}/...", "--add-modules", "ALL-MODULE-PATH", ...]
    ///
    ///    값만 사라지고 `-p` 는 남아서, 다음 원소인 `--add-modules` 가 `-p` 의 값으로 먹혔다.
    ///    JVM 은 `Error: -p requires module path specification` 으로 부팅 전에 죽는다.
    ///    덤으로 `-DlibraryDirectory` 와 `-DignoreList` 도 통째로 사라져서, 살아남더라도
    ///    BootstrapLauncher 가 모듈을 못 찾는다.
    ///
    ///    버리지 말고 **채워야 한다.**
    static func expandLoaderJvmArgs(_ args: [String], instanceDir: URL, mcVersion: String) -> [String] {
        let replacements = [
            "${library_directory}": instanceDir.appending(path: "libraries").path,
            "${classpath_separator}": ":",
            "${version_name}": mcVersion,
            "${natives_directory}": instanceDir.appending(path: "natives").path,
        ]
        var out: [String] = []
        for arg in args {
            var value = arg
            for (token, actual) in replacements { value = value.replacingOccurrences(of: token, with: actual) }
            // 모르는 자리표시자가 남았다면 채울 수 없는 인자다. 이때는 **짝까지 함께** 버린다 —
            // 값만 버리면 앞의 플래그가 다음 인자를 값으로 삼킨다(위 설명 참고).
            if value.contains("${") {
                if let last = out.last, last.hasPrefix("-"), !last.contains("=") { out.removeLast() }
                continue
            }
            out.append(value)
        }
        return out
    }

    /// MobileGlues 설정을 써 둔다. `MG_DIR_PATH/config.json` 을 읽는다.
    ///
    /// ⚠️ `enableExtDirectStateAccess` 를 **끈다.** 켜져 있으면 MobileGlues 가
    ///    `GL_ARB_direct_state_access` 를 광고하고, Iris 는 그걸 보고 DSA 경로를 탄다
    ///    (`glNamedFramebufferTexture` → 에뮬레이션 → `glFramebufferTexture`).
    ///    그런데 `glFramebufferTexture` 는 **ES 3.2 진입점**이고 우리 호스트(ANGLE Metal)는
    ///    ES 3.0 이라, 그 경로에서 어태치먼트가 조용히 유실된다.
    ///
    ///    실제 증상: 셰이더를 켜면 지형·엔티티는 나오는데 **플레이어 손만 사라졌다.**
    ///    지형은 draw buffer 구성이 고정이라 무사하고, gbuffers_hand 는 구성이 달라
    ///    어태치먼트 셔플·복구를 타기 때문이다.
    ///
    ///    끄면 Iris 가 고전 경로(`glFramebufferTexture2D` — ES 3.0 네이티브)를 쓴다.
    ///    번역 계층이 통째로 빠지므로 더 안전하다.
    static func writeMobileGluesConfig(in dir: URL) {
        let config: [String: Any] = [
            "enableExtDirectStateAccess": 0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.prettyPrinted]) else { return }
        try? data.write(to: dir.appending(path: "config.json"), options: .atomic)
    }

    static func repairUnreadableFiles(in dir: URL) {
        let fm = FileManager.default
        let marker = dir.appending(path: ".flame_perm_repaired")
        guard !fm.fileExists(atPath: marker.path) else { return }

        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker {
                guard let mode = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]
                        as? NSNumber, mode.intValue & 0o400 == 0 else { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                try? fm.setAttributes([.posixPermissions: isDir ? 0o755 : 0o644],
                                      ofItemAtPath: url.path)
            }
        }
        try? Data().write(to: marker)
    }

    func makePlan() throws -> LaunchPlan {
        // ⚠️ 심볼릭 링크를 푼 실제 경로를 쓴다.
        //    iOS 의 홈 경로는 /var/mobile/… 인데 실제로는 /private/var/mobile/… 이다.
        //    프로세스 CWD 는 chdir 이후 /private/var/… 로 잡히는데 -Duser.dir 만
        //    /var/… 로 남으면 둘이 문자열로 어긋난다. 상대 경로를 자기 방식으로 푸는
        //    라이브러리(Cobblemon 이 쓰는 GraalJS 등)가 여기서 걸린다.
        //
        //    ⚠️ `URL.resolvingSymlinksInPath()` 는 쓰면 안 된다 — 애플 구현은 오히려
        //       `/private` 접두어를 **떼어내는** 방향이라 /var/… 그대로 남는다.
        //       C 의 realpath 를 써야 커널이 보는 실제 경로가 나온다.
        let dir = Self.realPath(of: meta.dir)
        let renderer = RendererStore.resolve(for: meta)
        let modCount = InstanceStore.shared.modCount(meta)
        let javaMajor = Self.requiredJavaMajor(instanceDir: dir, mcVersion: meta.mcVersion)

        guard let java = JavaInstallStore.select(minVersion: javaMajor) else {
            throw LaunchError.noRuntime(javaMajor)
        }

        // options.txt / iris.properties 는 부팅 전에 맞춰둔다(게임이 시작하면서 읽는다).
        Paths.ensureDir(dir)

        // 마인크래프트는 logs/ · crash-reports/ · screenshots/ 를 **상대 경로**로 연다.
        // (log4j 의 RollingRandomAccessFile 이 "logs/latest.log" 를 그대로 쓴다)
        // 프로세스 CWD 를 인스턴스로 옮기지 않으면 읽기 전용인 앱 번들 기준이 돼서
        // FileNotFoundException 으로 로깅 초기화부터 실패한다.
        FileManager.default.changeCurrentDirectoryPath(dir.path)
        // ⚠️ HUD 크기는 **잘리지 않는 선까지만** 허용한다. 사용자가 4배를 골랐어도
        //    이 프레임버퍼에서 대형 상자가 잘리면 한 단계 내려서 쓴다
        //    (JvmSettings.tallestGuiHeight 참고).
        let framebuffer = (w: Int(screenSize.width), h: Int(screenSize.height))
        let hudScale = JvmSettings.effectiveHudScale(settings.hudScale,
                                                     framebufferHeight: framebuffer.h)
        let optionsGuiScale = GameOptions.sync(
            file: dir.appending(path: "options.txt"),
            settings: settings, modCount: modCount, versionId: meta.mcVersion,
            hudScale: hudScale
        )
        // 핫바 터치 영역이 화면 핫바와 정확히 겹치려면 **마인크래프트가 실제로 쓰는**
        // 스케일이어야 한다. 예전에는 뷰가 스스로 어림했는데, 뷰 좌표(pt)로 320x240 을
        // 나누는 바람에(마인크래프트는 프레임버퍼 px 로 나눈다) 절반짜리가 나왔다 —
        // 그래서 "핫바 터치 영역 크기" 수동 설정이 필요했다. 여기서 한 번만 정한다.
        let guiScale = JvmSettings.effectiveGuiScale(
            hudScale: settings.hudScale, optionsGuiScale: optionsGuiScale,
            framebuffer: framebuffer
        )
        GameOptions.syncIris(file: dir.appending(path: "config/iris.properties"))

        // 네이티브 라이브러리(LWJGL·렌더러·OpenAL)는 앱 번들 Frameworks/ 에 있다.
        //
        // LWJGL 3.4 를 요구하는 버전(26.2+)은 **전용 스택**을 앞에 둔다. Frameworks341/ 에는
        // LWJGL 네이티브 4개만 있고, 렌더러·OpenAL 등 나머지는 뒤쪽 Frameworks/ 에서 찾는다.
        // (org.lwjgl.librarypath 는 ':' 로 구분된 경로 목록을 받는다)
        let bundle = Bundle.main.bundleURL
        let useLwjgl34 = Self.needsLwjgl34(instanceDir: dir, mcVersion: meta.mcVersion)
        let baseFrameworks = bundle.appending(path: "Frameworks").path
        let frameworks = useLwjgl34
            ? bundle.appending(path: "Frameworks/lwjgl341").path + ":" + baseFrameworks
            : baseFrameworks

        var argv = [java.home.appending(path: "bin/java").path]
        Self.repairUnreadableFiles(in: dir)
        Self.neutralizeMacOnlyModOptions(in: dir)
        Self.disableForgeEarlyWindow(in: dir)

        // 컨테이너가 바뀌었으면 계획의 낡은 절대경로를 고쳐준다.
        ForgeInstallPlanner.migrateIfNeeded(instanceDir: dir)

        // 부트스트랩이 읽는 값. 계획이 없으면 프로퍼티만 남고 아무 일도 안 한다.
        let planFile = dir.appending(path: ForgeInstallPlanner.planFileName)
        if FileManager.default.fileExists(atPath: planFile.path) {
            argv += [
                "-Dflame.main.class=\(meta.mainClass)",
                "-Dflame.forge.plan=\(planFile.path)",
            ]
            // 프로세서가 부르는 System.exit 를 막으려면 SecurityManager 설치가 필요하다.
            // ⚠️ "allow" 는 JDK 12+ 에서만 특별한 값이다. Java 8 은 이걸 **클래스 이름**으로
            //    읽고 못 찾아 JVM 이 죽는다 — 그리고 Java 8 은 이 설정 없이도 설치를 허용한다.
            if java.majorVersion >= 12 { argv.append("-Djava.security.manager=allow") }
        }
        argv += settings.jvmArgs(
            instanceDir: dir,
            userDir: dir.path,
            libraryPath: frameworks,
            mainClass: meta.mainClass,
            javaMajor: java.majorVersion,
            renderer: renderer,
            screenSize: (Int(screenSize.width), Int(screenSize.height))
        )
        argv.append("-DUIScreen.maximumFramesPerSecond=\(UIScreen.main.maximumFramesPerSecond)")

        // HUD 확대: 마인크래프트의 320x240 하한을 에이전트가 낮추도록 알려준다.
        // (왜 이렇게까지 하는지는 JvmSettings.hudScale / IosFsAgent.patchGuiFloor 참고)
        if let floor = JvmSettings.guiFloorSpec(hudScale: settings.hudScale,
                                                framebuffer: framebuffer) {
            argv.append("-Dflame.guiFloor=\(floor)")
        }
        let loaderArgs = Self.expandLoaderJvmArgs(meta.gameJvmArgs, instanceDir: dir, mcVersion: meta.mcVersion)
        argv += loaderArgs

        // 클래스패스와 메인 클래스는 JLI 가 `java` 명령처럼 해석한다.
        argv += ["-cp", buildClassPath(excluding: Self.modulePathEntries(loaderArgs))]
        // Forge/NeoForge 설치 계획이 남아 있으면 게임보다 먼저 돌려야 한다.
        // iOS 는 설치 전용 JVM 을 못 띄우므로 이 JVM 안에서 처리한다.
        let plan = dir.appending(path: ForgeInstallPlanner.planFileName)
        if FileManager.default.fileExists(atPath: plan.path) {
            argv.append("kr.co.donghyun.flame.Bootstrap")
        } else {
            argv.append(meta.mainClass)
        }
        argv += buildMcArgs()

        var env = renderer.environment
        env["POJAV_NATIVEDIR"] = frameworks
        env["HOME"] = Paths.external.path
        // 26.3 은 SDL 이 게임 창과 그 뷰 컨트롤러를 따로 만든다. 힌트가 없으면 SDL 은 창 크기로
        // 방향을 정해(세로로 긴 순간이 있으면 세로 허용) 앱의 가로 고정과 어긋날 수 있다.
        env["SDL_ORIENTATIONS"] = "LandscapeLeft LandscapeRight"
        // 26.3 은 화면이 열리며 입력칸에 스스로 포커스를 주고(싱글플레이의 월드 검색칸 등),
        // SDL 은 그때마다 iOS 키보드를 자동으로 띄운다 — 들어가자마자 키보드가 화면을 가렸다.
        // 자동 표시만 끈다. 키보드는 다른 버전처럼 키보드 버튼으로 열고, 입력은 그대로 간다.
        // ⚠️ 이 힌트만으로는 안 막힌다 — 실제 차단은 flame_sdl.m 의 flame_suppressSDLAutoKeyboard.
        env["SDL_ENABLE_SCREEN_KEYBOARD"] = "0"

        // ⚠️ MobileGlues 는 "아는 런처"(FCL/ZaLith/PGW/플러그인)가 아니면 설정을 전부
        //    기본값으로 되돌린다 — compute shader·FSR1·GLSL 캐시가 통째로 꺼진다
        //    (config/settings.cpp). MG_DIR_PATH 를 주면 그 폴더의 config.json 을 쓴다.
        if renderer == .mobileglues {
            let dir = Paths.external.appending(path: "mobileglues")
            Paths.ensureDir(dir)
            env["MG_DIR_PATH"] = dir.path
            Self.writeMobileGluesConfig(in: dir)

            // ── 무거운 모드팩에서는 텍스처 아틀라스를 강제로 줄인다 ──────────────
            //
            // MobileGlues 의 기본 판단은 "지금 남은 여유로 이 할당이 들어가는가" 다.
            // 그런데 자바 힙은 그 뒤로도 -Xmx 까지 자란다. 아틀라스를 만들 때는 자리가
            // 있어도, 힙이 다 자라고 나면 없다.
            //
            // 실측(CobbleVerse, 모드 308개): 8192×4096 아틀라스는 "들어간다"고 판정돼
            // 그대로 잡혔고, 곧 자바 힙이 1436M/1536M 로 차면서 G1 이 Evacuation
            // Failure 를 33회 내며 제자리걸음에 빠졌다. 크래시도 아니고 끝나지도 않는다.
            //
            // 모드가 많은 팩은 힙이 어차피 상한까지 갈 것이 거의 확실하므로, 그때는
            // 아틀라스 쪽을 먼저 양보시킨다. 4096 이면 8192×4096 이 4096×2048 로 잡혀
            // 100MB 남짓이 힙 몫으로 돌아간다. 텍스처는 흐려지지만 돌아가기는 한다.
            //
            // ⚠️ 가벼운 인스턴스에는 걸지 않는다. 바닐라까지 흐려질 이유가 없다.
            // 모드가 많을수록 자바 힙이 더 필요하고, 그만큼 텍스처가 쓸 자리가 줄어든다.
            // 그래서 상한을 단계로 둔다.
            //
            // ⚠️ 판단 근거를 두 가지로 둔다. mods/ 의 jar 수만 보면 놓친다 —
            //    모드팩은 중첩 jar 가 많아서 파일 수가 실제 모드 수보다 훨씬 적다
            //    (CobbleVerse 는 패브릭이 308개를 읽는데 이 값은 150 미만이었다).
            //    그래서 모드팩 인스턴스는 최소 한 단계는 적용받게 한다.
            let isModpack = meta.id.hasPrefix("modpack_")
            let byModCount: Int? = {
                if modCount >= 100 { return 2048 }   // 8192² → 2048². 흐려지지만 돌아간다
                if modCount >= 50 || isModpack { return 4096 }
                return nil                            // 가벼운 인스턴스는 적응 규칙에 맡긴다
            }()


            // ⚠️ **화면보다 작게는 절대 못 잡는다.**
            //
            //    MobileGlues 의 축소는 "이 상한을 넘는 텍스처"에 걸리는데, 마인크래프트의
            //    메인 렌더 타깃도 그냥 텍스처다. 상한이 화면보다 작으면 렌더 타깃까지
            //    줄여서 화면이 잘린다 — 실제로 그렇게 됐다:
            //      MGTEX 1533x707 -> 766x353 (상한 1024 강제)
            //    화면 크기 이하는 애초에 줄일 이유도 없다(그건 감당되는 크기다).
            let screenMax = max(framebuffer.w, framebuffer.h)
            let atlasCap = byModCount.map { max($0, screenMax) }
            if let atlasCap {
                env["MG_MAX_TEXTURE_DIM"] = String(atlasCap)
            }

            // ⚠️ 무거운 인스턴스는 **파일 기반 매핑 임계값을 낮춘다**.
            //
            //    기본 256 KB 는 아틀라스·큰 버퍼만 잡는다. 그런데 리소스팩 스프라이트는
            //    한 장이 16~64 KB 라 그 그물을 빠져나가고, 수천 장이 모여 익명 메모리로
            //    남는다 — 실측 `malloc_small` 297 MB(바닐라+서버팩), 코블버스에서는
            //    힙 밖이 986 MB 까지 올라갔다.
            //    마인크래프트는 스티칭이 끝나도 스프라이트마다 원본 NativeImage 를
            //    `SpriteContents` 안에 계속 들고 있어서 해제되지도 않는다.
            //
            //    32 KB 로 내리면 그것들도 파일로 빠진다. 대신 매핑 수가 수천 개로 늘고
            //    16 KB 페이지 정렬 때문에 낭비가 생기므로(그 낭비도 파일이라 장부에는
            //    안 잡힌다) 가벼운 인스턴스에는 걸지 않는다.
            if modCount >= 50 || isModpack {
                env["FLAME_ALLOC_MMAP_MIN"] = "32768"
            }

            // 26.3+ 준비: SDL3 가 이 프로세스에서 초기화되는지 한 번 재 본다.
            // ⚠️ 재보기만 하고 바로 SDL_Quit 한다(flame_sdl.m). 결과가 나오면 지운다.
            env["FLAME_SDL_PROBE"] = "1"

            // ⚠️ 리소스 리로드의 **동시성**을 줄여 피크 라이브 셋 자체를 낮춘다.
            //
            //    마인크래프트는 `Util.backgroundExecutor()` 로 워커를 코어 수만큼 띄우고
            //    (`Worker-ResourceReload-0..4`), 각 워커가 디코드한 이미지를 동시에 들고
            //    있는다. 그래서 피크가 코어 수에 비례해 부푼다.
            //
            //    실측(코블버스): "Loading animations..." 구간에서 힙이 2048 중 1928 까지
            //    차고 G1 이 17.2초짜리 full GC 를 돌기 시작한다. 힙을 1920 → 2047 로
            //    키워 봤지만 같은 자리에서 막혔다 — 줄 수 있는 양의 문제가 아니라
            //    **한 번에 필요한 양**의 문제다.
            //
            //    `max.bg.threads` 는 마인크래프트가 직접 읽는 값이다(Util.getMaxThreads).
            //    줄이면 리로드가 느려지는 대신 동시에 살아 있는 이미지가 줄어든다.
            // ⚠️ env 로 준다. 여기서 argv.append 하면 **게임 인자**로 들어간다 —
            //    이 블록은 JVM 인자 구성이 끝난 뒤라 메인 클래스 뒤에 붙는다.
            //    실제로 마인크래프트가 이렇게 무시했다:
            //      Completely ignored arguments: [--userType, msa, -Dmax.bg.threads=2]
            env["JDK_JAVA_OPTIONS"] = ((env["JDK_JAVA_OPTIONS"] ?? "") + " -Dmax.bg.threads=2")
                .trimmingCharacters(in: .whitespaces)
            print("[Flame] 모드 \(modCount)개\(isModpack ? " (모드팩)" : "")"
                  + String(localized: " · 아틀라스 상한 ") + (atlasCap.map(String.init) ?? String(localized: "없음")))
        }

        return LaunchPlan(javaHome: java.home, argv: argv, env: env,
                          renderer: renderer, guiScale: guiScale, modCount: modCount)
    }

    /// 클라이언트 JAR + 라이브러리 + 로더 JAR 을 `:` 로 이은 클래스패스.
    ///
    /// ⚠️ 번들의 `libs/` 에 있는 **패치된 LWJGL** 이 맨 앞에 와야 한다. 마인크래프트가 받아온
    ///    원본 lwjgl jar 이 먼저 오면 GLFW 가 진짜 데스크톱 GLFW 를 찾다 죽는다.
    /// - Parameter excluding: 모듈 경로(`-p`)에 이미 올린 jar. 클래스패스에서 뺀다.
    private func buildClassPath(excluding modulePath: Set<String> = []) -> String {
        let dir = meta.dir
        var entries: [String] = []

        // 1) 패치된 LWJGL (앱 번들)
        // 26.2+ 는 LWJGL 3.4.1 판 jar 을 쓴다. 나머지 jar(launcher/patchjna/bootstrap)은
        // 양쪽 폴더에 같은 것이 들어 있으므로 폴더만 갈아끼우면 된다.
        let libs = Bundle.main.bundleURL
            .appending(path: Self.needsLwjgl34(instanceDir: meta.dir, mcVersion: meta.mcVersion)
                       ? "libs341" : "libs")
        if let jars = try? FileManager.default.contentsOfDirectory(at: libs, includingPropertiesForKeys: nil) {
            entries += jars.filter { $0.pathExtension == "jar" }.map(\.path).sorted()
        }

        // 2) 로더가 넣은 JAR — 바닐라 라이브러리보다 앞에 와야 패치된 클래스가 이긴다.
        entries += meta.extraJars.map { dir.appending(path: $0).path }

        // 3) 바닐라 라이브러리
        // Forge 설치 도구 전용 라이브러리는 게임 클래스패스에서 뺀다(모듈 충돌 방지).
        // 설치 전용 라이브러리 + 프로세서 산출물. 둘 다 게임 클래스패스에서 뺀다.
        // ⚠️ 바닐라가 요구하는 라이브러리는 무슨 일이 있어도 빼지 않는다.
        //    설치 계획(forge_plan.json)은 로더 프로파일만 보고 "설치 전용"을 골라내는데,
        //    Forge 의 프로파일은 바닐라를 inheritsFrom 으로 상속받아서 gson·guava 같은
        //    공통 라이브러리를 자기 목록에 담지 않는다. 그래서 프로세서용으로 받아 둔
        //    같은 라이브러리가 설치 전용으로 분류되어 게임에서 통째로 사라진다:
        //      NoClassDefFoundError: com/google/gson/JsonSyntaxException
        //    설치 쪽은 고쳤지만, **이미 만들어진 인스턴스의 계획 파일은 그대로**라
        //    여기서 한 번 더 막는다(재설치 없이 살아난다).
        let vanillaNeeded = ForgeProcessorRunner.vanillaLibraryPaths(instanceDir: dir,
                                                               mcVersion: meta.mcVersion)
        // ⚠️ 프로세서 산출물 제외는 **모듈 경로를 쓸 때만** 옳다.
        //
        //    NeoForge 는 -p 로 모듈 경로를 구성하고 FML 이 산출물을 -DlibraryDirectory +
        //    maven 좌표로 직접 찾는다. 그때 같은 것을 클래스패스에도 두면 같은 패키지를
        //    두 모듈이 export 해서 해석이 실패한다:
        //      ResolutionException: Modules minecraft and neoforge export package …
        //
        //    그런데 Forge 52 는 -p 를 쓰지 않는다. ForgeBootstrap 이 **클래스패스로**
        //    SECURE-BOOTSTRAP 을 만들기 때문에, 마지막 프로세서가 만든 패치된 클라이언트
        //    (forge-<ver>-client.jar, 26.8MB — 이게 곧 게임이다)가 거기 있어야 한다.
        //    빼면 이렇게 죽는다:
        //      IllegalStateException: Could not find net/minecraft/client/Minecraft.class
        //
        //    중간 산출물(client-*-official.jar 등)은 모듈 경로와 무관하게
        //    isLoaderIntermediateJar 가 따로 걸러낸다.
        let processorOutputs = modulePath.isEmpty
            ? []
            : ForgeInstallPlanner.outputPaths(instanceDir: dir)
        let installOnly = ForgeInstallPlanner.installOnlyPaths(instanceDir: dir)
            .union(processorOutputs)
            .subtracting(vanillaNeeded)
        let librariesDir = dir.appending(path: "libraries")
        if let walker = FileManager.default.enumerator(at: librariesDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "jar" {
                // 원본 LWJGL 은 전부 제외한다(위 1번의 병합 jar 이 대신한다).
                guard !Self.shouldDropVanillaLwjgl(url.lastPathComponent) else { continue }
                // ⚠️ 이름에 `@` 가 있는 건 좌표를 잘못 푼 잔재다(`...-mappings@tsrg.jar` 처럼
                //    텍스트 파일이 .jar 로 저장된 것). 클래스패스에 넣으면 Forge 부트스트랩이
                //    zip 으로 열다 "zip END header not found" 로 죽는다.
                guard !url.lastPathComponent.contains("@") else { continue }
                // ⚠️ text2speech 는 libs/launcher.jar 이 iOS 용 스텁으로 대체한다.
                //    원본까지 같이 두면 Forge 의 모듈 경로에서 같은 패키지를 두 모듈이
                //    export 하게 되어 부팅이 막힌다:
                //      "Modules text2speech and launcher export package com.mojang.text2speech"
                //    (Fabric 은 모듈 경로를 안 써서 드러나지 않았다)
                guard !url.lastPathComponent.hasPrefix("text2speech") else { continue }
                let relative = url.path.replacingOccurrences(of: dir.path + "/", with: "")
                guard !installOnly.contains(relative) else { continue }
                entries.append(url.path)
            }
        }

        // 4) 클라이언트 JAR
        entries.append(dir.appending(path: "versions/\(meta.mcVersion)/\(meta.mcVersion).jar").path)

        // 모듈 경로에 올라간 아티팩트는 **버전이 달라도** 클래스패스에서 뺀다.
        let moduleArtifacts = Set(modulePath.map(Self.artifactKey))
        var seen = Set<String>()
        return entries
            .filter { !modulePath.contains($0) && !moduleArtifacts.contains(Self.artifactKey($0)) }
            .filter { !Self.isLoaderIntermediateJar($0) }
            .filter { seen.insert(Self.libraryKey($0)).inserted }   // 같은 라이브러리는 먼저 온 한 벌만
            .joined(separator: ":")
    }

    /// 게임 인자. 1.12 이하는 매니페스트가 준 placeholder 문자열을 치환하고,
    /// 1.13+ 는 표준 `--key value` 목록을 만든다. 안드로이드와 같은 분기.
    /// 1.7.2 이하의 옛 에셋 배치를 만든다 — 그 시절 게임은 해시 폴더(objects/)를 모르고
    /// **파일 이름 그대로** 찾는다. 이게 없으면 1.6~1.7.2 는 메뉴 글자가 번역 키로 나오고,
    /// 1.5.2 이하는 소리가 전부 빠진다.
    ///  - `virtual` (1.6~1.7.2 의 "legacy")         → assets/virtual/<id>/
    ///  - `map_to_resources` (1.5.2 이하 "pre-1.6") → 위 + 게임 폴더의 resources/
    /// 이미 있는 파일은 건너뛴다(하드 링크라 용량도 거의 안 든다). 돌려준 경로가 ${game_assets} 다.
    static func prepareLegacyAssets(instanceDir: URL, indexId: String) -> URL? {
        struct Index: Decodable {
            struct Object: Decodable { let hash: String }
            let objects: [String: Object]
            let virtual: Bool?
            let map_to_resources: Bool?
        }
        let assets = Paths.assets(for: instanceDir)
        guard let data = try? Data(contentsOf: assets.appending(path: "indexes/\(indexId).json")),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              index.virtual == true || index.map_to_resources == true
        else { return nil }

        let virtualDir = assets.appending(path: "virtual/\(indexId)")
        var roots = [virtualDir]
        if index.map_to_resources == true { roots.append(instanceDir.appending(path: "resources")) }
        let fm = FileManager.default
        for (name, object) in index.objects {
            let source = assets.appending(path: "objects/\(object.hash.prefix(2))/\(object.hash)")
            guard fm.fileExists(atPath: source.path) else { continue }
            for root in roots {
                let dest = root.appending(path: name)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fm.linkItem(at: source, to: dest)) == nil { try? fm.copyItem(at: source, to: dest) }
            }
        }
        return virtualDir
    }

    private func buildMcArgs() -> [String] {
        let dir = meta.dir
        let username = session?.username ?? "Player"
        let uuid = session?.uuid ?? "00000000-0000-0000-0000-000000000000"
        let accessToken = session?.accessToken ?? "0"
        let userType = session != nil ? "msa" : "mojang"
        let assetsDir = Paths.assets(for: dir).path
        let versionType = meta.loaderType.map { $0.capitalized } ?? "release"

        // 매니페스트가 준 인자 안에 `${...}` 가 있다는 사실 자체가 레거시 포맷 시그널이다.
        let metaArgs = meta.gameArgs
        if metaArgs.contains(where: { $0.contains("${") }) {
            let placeholders = [
                "${auth_player_name}": username,
                "${auth_session}": "token:\(accessToken):\(uuid)",   // 1.5.x 시절 단일 토큰 포맷
                "${auth_uuid}": uuid,
                "${auth_access_token}": accessToken,
                "${version_name}": meta.mcVersion,
                "${game_directory}": dir.path,
                "${game_assets}": Self.prepareLegacyAssets(instanceDir: dir, indexId: meta.assetIndexId)?.path
                    ?? assetsDir,
                "${assets_root}": assetsDir,
                "${assets_index_name}": meta.assetIndexId,
                "${user_type}": userType,
                "${version_type}": versionType,
                "${user_properties}": "{}",
                "${profile_name}": username,
                "${launcher_name}": "FlameLauncher",
                "${launcher_version}": "2.0",
            ]
            return metaArgs.map { arg in
                placeholders.reduce(arg) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
            }
        }

        return [
            "--username", username,
            "--version", meta.mcVersion,
            "--gameDir", dir.path,
            "--assetsDir", assetsDir,
            "--assetIndex", meta.assetIndexId,
            "--uuid", uuid,
            "--accessToken", accessToken,
            "--userType", userType,
            "--versionType", versionType,
        ] + metaArgs
    }
}
