import XCTest
import Compression
@testable import FlameLauncher

/// 런타임 없이도 깨지면 바로 드러나야 하는 것들만 확인한다.
/// (네트워크·JVM·UI 는 여기서 다루지 않는다 — 붙여봐야 느리고 잘 깨지기만 한다.)
final class FlameLauncherTests: XCTestCase {

    // MARK: - ZIP 리더

    /// 실제 zip 아카이브를 만들어 읽는다. deflate 경로가 살아 있는지가 핵심 —
    /// 모드팩·리소스팩·jar 가 전부 이 경로로 들어온다.
    func testZipRoundTrip() throws {
        let payload = Data(String(repeating: "flame launcher ", count: 400).utf8)
        let archive = try makeZip(entries: [("hello.txt", payload), ("dir/sub.bin", Data([1, 2, 3]))])

        let entries = try Zip.entries(of: archive)
        XCTAssertEqual(entries.count, 2)

        let hello = try XCTUnwrap(entries.first { $0.path == "hello.txt" })
        XCTAssertEqual(try Zip.read(hello, from: archive), payload)

        let sub = try XCTUnwrap(entries.first { $0.path == "dir/sub.bin" })
        XCTAssertEqual(try Zip.read(sub, from: archive), Data([1, 2, 3]))
    }

    /// ⚠️ 번들 `libs/` 는 클래스패스 **맨 앞**이라(패치된 LWJGL 이 먼저 와야 한다)
    /// 여기 있는 jar 은 게임이 들고 온 같은 라이브러리를 가린다.
    ///
    /// 실제로 gson 2.13.1 이 마인크래프트의 2.10.1 을 가려서 CobbleVerse 가 죽었다 —
    /// 2.11 부터 TypeToken 이 타입 변수를 거부해서 rctmod 가 부팅 중에 터진다.
    /// 우리가 패치했거나 직접 만든 것만 있어야 한다.
    func testBundledLibsDoNotShadowGameLibraries() throws {
        let libs = Bundle.main.bundleURL.appending(path: "libs")
        let jars = try FileManager.default.contentsOfDirectory(atPath: libs.path)
            .filter { $0.hasSuffix(".jar") }
        XCTAssertFalse(jars.isEmpty, "번들에 libs/*.jar 이 없습니다")

        // lwjgl: GLFW 를 우리 브릿지로 돌린 패치본 / launcher: iOS 용 대체 클래스
        // patchjna_agent: JNA 를 iOS 로 인식시키는 에이전트 / flame_bootstrap: 우리 코드
        let ours: Set<String> = ["lwjgl.jar", "launcher.jar",
                                 "patchjna_agent.jar", "flame_bootstrap.jar"]
        let unexpected = Set(jars).subtracting(ours)
        XCTAssertTrue(unexpected.isEmpty,
                      "게임 라이브러리를 가릴 수 있는 jar: \(unexpected.sorted())")
    }

    /// 원본 text2speech 는 클래스패스에서 빼고 스텁으로 대체하는데, 스텁에
    /// `Narrator.InitializeException` 이 빠져 있으면 MinecraftClient 가 그 타입을 풀다
    /// NoClassDefFoundError 로 죽는다 (CobbleVerse 가 실제로 여기서 터졌다).
    func testNarratorStubHasInitializeException() throws {
        let jar = Bundle.main.bundleURL.appending(path: "libs/launcher.jar")
        let entries = try Zip.entries(of: Data(contentsOf: jar)).map(\.path)
        // 실제로 게임·모드가 이름으로 찾다가 NoClassDefFoundError 를 냈던 것들이다.
        for required in ["Narrator", "Narrator$InitializeException",
                         "OperatingSystem",   // ModernFix GameNarratorMixin
                         "NarratorMac"] {
            XCTAssertTrue(entries.contains("com/mojang/text2speech/\(required).class"),
                          "스텁에 \(required) 가 없습니다")
        }
    }

    /// FancyMenu 의 macOS 아이콘 경로를 비우는 처리. 다른 줄은 건드리면 안 된다 —
    /// 16/32 PNG 아이콘과 창 제목은 그대로 살아 있어야 한다.
    func testNeutralizeFancyMenuMacIcon() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "fm-\(UUID().uuidString)")
        let options = dir.appending(path: "config/fancymenu/options.txt")
        try FileManager.default.createDirectory(at: options.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = """
        ##[window]

        B:show_custom_window_icon = 'true';
        S:custom_window_icon_macos = '/config/fancymenu/assets/cobbleverse_icon_32.icns';
        S:custom_window_icon_32 = '/config/fancymenu/assets/cobbleverse_icon_32.png';
        S:custom_window_title = 'COBBLEVERSE';
        """
        try original.write(to: options, atomically: true, encoding: .utf8)

        GameLauncher.neutralizeMacOnlyModOptions(in: dir)
        let after = try String(contentsOf: options, encoding: .utf8)

        XCTAssertTrue(after.contains("S:custom_window_icon_macos = '';"))
        XCTAssertFalse(after.contains(".icns"))
        // 나머지는 그대로여야 한다.
        XCTAssertTrue(after.contains("B:show_custom_window_icon = 'true';"))
        XCTAssertTrue(after.contains("cobbleverse_icon_32.png"))
        XCTAssertTrue(after.contains("S:custom_window_title = 'COBBLEVERSE';"))

        // 두 번 돌려도 같아야 한다.
        GameLauncher.neutralizeMacOnlyModOptions(in: dir)
        XCTAssertEqual(try String(contentsOf: options, encoding: .utf8), after)
    }

    /// ⚠️ 버전 목록은 앱 시작 때 한 번만 가져왔고, 실패하면 그 세션 내내 빈 목록이었다.
    /// 모드팩 설치가 이 목록에서 베이스 버전을 찾으므로 설치까지 조용히 막혔다.
    /// 실제 응답이 우리 모델로 디코딩되는지도 같이 고정한다 — 여기가 깨지면 같은 증상이다.
    func testVersionManifestDecodes() throws {
        let json = """
        {"latest":{"release":"1.21.1","snapshot":"24w33a"},
         "versions":[
           {"id":"1.21.1","type":"release",
            "url":"https://piston-meta.mojang.com/v1/packages/x/1.21.1.json",
            "time":"2024-08-08T12:24:45+00:00","releaseTime":"2024-08-08T12:24:45+00:00"}]}
        """
        let index = try JSONDecoder().decode(VersionManifestIndex.self, from: Data(json.utf8))
        XCTAssertEqual(index.latest.release, "1.21.1")
        XCTAssertEqual(index.versions.count, 1)
        XCTAssertTrue(index.versions[0].isRelease)
        // 실제 매니페스트에는 우리가 안 읽는 "time" 키가 더 있다 — 무시되어야 한다.
        XCTAssertEqual(index.versions[0].id, "1.21.1")
    }

    /// ⚠️ JIT 자동 호출 URL 은 Amethyst 와 **같은 규약**이어야 한다 —
    /// StikDebug 가 파싱하는 쿼리 이름이 조금이라도 다르면 조용히 무시된다.
    /// 특히 `script-data` 가 빠지면 사용자가 StikDebug 안에서 스크립트를 직접 골라야 하고,
    /// 그 지정은 앱을 다시 설치할 때마다 풀린다.
    func testJITScriptIsBundledForHandoff() throws {
        // URL 에 실어 보낼 스크립트가 번들에 있어야 한다.
        let script = Bundle.main.url(forResource: "UniversalJIT26", withExtension: "js")
        XCTAssertNotNil(script, "UniversalJIT26.js 가 번들에 없습니다 — script-data 를 못 보냅니다")

        let data = try Data(contentsOf: try XCTUnwrap(script))
        XCTAssertGreaterThan(data.count, 1000, "JIT 스크립트가 비어 있습니다")
        // base64 로 실어 보내므로 URL 쿼리에 넣을 수 있어야 한다.
        let encoded = data.base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        XCTAssertNotNil(encoded)
    }

    /// 업데이트 노트는 GitHub 가 렌더한 HTML 조각이라, 우리 껍데기·CSS 가 씌워져야
    /// GitHub 처럼 보인다. 껍데기가 빠지면 흰 배경 세리프로 나온다.
    func testReleaseNotesPageWrapsFragment() {
        let page = ReleaseNotes.page(wrapping: #"<article class="markdown-body"><h1>Hi</h1></article>"#)
        XCTAssertTrue(page.hasPrefix("<!doctype html>"))
        XCTAssertTrue(page.contains("markdown-body"))
        XCTAssertTrue(page.contains("<h1>Hi</h1>"), "조각 본문이 유실됐다")
        // 팔레트와 같은 색이어야 한다 — 여기만 예전 색이 남으면 그 화면만 튄다.
        XCTAssertTrue(page.contains("#05080F"), "배경이 팔레트의 bgDark 가 아니다")
        XCTAssertTrue(page.contains("#2E9BFF"), "링크색이 팔레트의 primary 가 아니다")
        XCTAssertTrue(page.contains("color-scheme: dark"))
    }

    /// ⚠️ DSA 를 켜 두면 Iris 가 `glNamedFramebufferTexture` → ES 3.2 진입점으로 내려가고,
    /// ANGLE Metal(ES 3.0)에서 어태치먼트가 조용히 유실된다 — 셰이더를 켜면 손이 사라졌다.
    func testMobileGluesConfigDisablesDSA() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        GameLauncher.writeMobileGluesConfig(in: dir)

        let data = try Data(contentsOf: dir.appending(path: "config.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // MobileGlues 는 config_get_int 로 읽는다 — 반드시 **숫자**여야 한다(불리언은 무시된다).
        XCTAssertEqual(json["enableExtDirectStateAccess"] as? Int, 0)
    }

    // MARK: - 콘텐츠 설치 경로

    /// 셰이더·리소스팩·맵은 전부 `.zip` 이다. 예전에는 확장자로 모드팩을 가려내서
    /// 셰이더를 설치하면 "modrinth.index.json / manifest.json" 오류로 막혔다.
    /// 종류는 **탐색한 탭**이 정한다 — 그 대응이 어긋나면 여기서 깨진다.
    func testInstallFolderPerContentType() {
        XCTAssertEqual(ContentType.mod.installFolder, "mods")
        XCTAssertEqual(ContentType.resourcepack.installFolder, "resourcepacks")
        XCTAssertEqual(ContentType.shader.installFolder, "shaderpacks")
        XCTAssertEqual(ContentType.world.installFolder, "saves")

        // 모드팩만 새 인스턴스를 만든다. 나머지는 전부 기존 인스턴스에 넣는다.
        for type in ContentType.allCases where type != .modpack {
            XCTAssertNotEqual(type.installFolder, ".", "\(type) 가 인스턴스 루트로 들어간다")
        }
    }

    /// Modrinth 에는 맵 종류가 없다. datapack facet 은 모드를 돌려주므로
    /// 그 탭을 열어두면 모드 jar 가 saves/ 로 떨어진다.
    func testModrinthHasNoWorldTab() {
        XCTAssertNil(ContentType.world.modrinthProjectType)
        XCTAssertFalse(ContentType.tabs(for: .modrinth).contains(.world))
        XCTAssertEqual(ContentType.tabs(for: .curseforge), ContentType.allCases)
    }

    /// CurseForge classId ↔ 설치 폴더. 모드팩 manifest 는 이 값으로만 종류를 구분한다.
    func testCurseForgeClassIds() {
        XCTAssertEqual(ContentType.mod.curseForgeClassId, 6)
        XCTAssertEqual(ContentType.resourcepack.curseForgeClassId, 12)
        XCTAssertEqual(ContentType.world.curseForgeClassId, 17)
        XCTAssertEqual(ContentType.shader.curseForgeClassId, 6552)
        XCTAssertEqual(ContentType.modpack.curseForgeClassId, 4471)
    }

    /// iOS 샌드박스는 /private·/var 를 stat 조차 막아서 realpath(3) 이 멀쩡한 경로에도
    /// EPERM 을 준다 — 그래서 Path.toRealPath() 가 **항상** 실패하고, 그걸 쓰는 모드가
    /// 그대로 멈춘다. 막혔을 때 대신 쓰는 정규화가 이 함수다.
    func testLexicalRealpath() {
        func resolve(_ path: String) -> String {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            FlameNativeLexicalRealpath(path, &buffer)
            return String(cString: buffer)
        }

        XCTAssertEqual(resolve("/var/mobile/./Documents"), "/var/mobile/Documents")
        XCTAssertEqual(resolve("/var/mobile/foo/../Documents"), "/var/mobile/Documents")
        XCTAssertEqual(resolve("/a/b/c/../../d"), "/a/d")
        XCTAssertEqual(resolve("/a//b///c"), "/a/b/c")
        XCTAssertEqual(resolve("/a/b/"), "/a/b")
        // 루트 위로는 올라가지 않는다.
        XCTAssertEqual(resolve("/../.."), "/")
        XCTAssertEqual(resolve("/a/../../b"), "/b")
        XCTAssertEqual(resolve("/"), "/")
        // 상대경로는 cwd 기준 — 앞이 무엇이든 절대경로로 끝나야 한다.
        XCTAssertTrue(resolve("foo/bar").hasSuffix("/foo/bar"))
        XCTAssertTrue(resolve("foo/bar").hasPrefix("/"))
    }

    func testZipRejectsNonArchive() {
        XCTAssertThrowsError(try Zip.entries(of: Data(repeating: 0, count: 64)))
    }

    // MARK: - 메이븐 좌표

    /// Forge 설치 프로필은 `@확장자` 를 쓴다. 이걸 놓치면 텍스트 매핑이 `.jar` 로 저장돼
    /// 클래스패스에 딸려 들어가고 Forge 부트스트랩이 zip 으로 열다 죽는다.
    func testMavenPathWithExtension() {
        XCTAssertEqual(Maven.path("net.minecraft:client:1.21.1:mappings@tsrg"),
                       "net/minecraft/client/1.21.1/client-1.21.1-mappings.tsrg")
        XCTAssertEqual(Maven.path("net.neoforged:neoform:1.21.1-20240808@zip"),
                       "net/neoforged/neoform/1.21.1-20240808/neoform-1.21.1-20240808.zip")
    }

    /// 보이지 않는 키 입력 대상은 친 글자를 그대로, 줄바꿈은 엔터로, 지우기는 백스페이스로 보낸다.
    func testGameKeyInputMapsKeys() {
        let view = GameKeyInputView()
        var chars: [UInt32] = []
        var backspaces = 0
        var returns = 0
        view.onChar = { chars.append($0) }
        view.onBackspace = { backspaces += 1 }
        view.onReturn = { returns += 1 }

        view.insertText("가a")
        view.deleteBackward()
        view.insertText("\n")

        XCTAssertEqual(chars, [0xAC00, 0x61])
        XCTAssertEqual(backspaces, 1)
        XCTAssertEqual(returns, 1)
        XCTAssertTrue(view.hasText, "false 면 키보드가 지우기를 보내지 않는다")
    }

    func testMavenPath() {
        XCTAssertEqual(Maven.path("net.fabricmc:fabric-loader:0.16.9"),
                       "net/fabricmc/fabric-loader/0.16.9/fabric-loader-0.16.9.jar")
        XCTAssertEqual(Maven.path("org.lwjgl:lwjgl:3.3.3:natives-macos"),
                       "org/lwjgl/lwjgl/3.3.3/lwjgl-3.3.3-natives-macos.jar")
    }

    // MARK: - 버전 판정

    /// b1.7.3 이 modern 으로 오판되면 cacio 주입 방식이 어긋나 실행 즉시 죽는다 —
    /// 안드로이드에서 실제로 났던 버그라 회귀 방지로 남긴다.
    func testLegacyVersionDetection() {
        XCTAssertTrue(VersionRules.isLegacy("b1.7.3"))
        XCTAssertTrue(VersionRules.isLegacy("a1.2.6"))
        XCTAssertTrue(VersionRules.isLegacy("1.12.2"))
        XCTAssertFalse(VersionRules.isLegacy("1.13"))
        XCTAssertFalse(VersionRules.isLegacy("1.21.4"))
        XCTAssertEqual(VersionRules.javaMajor("1.12.2"), 8)
        // 1.20.5 부터 Java 21 이다. 17 로 고르면 UnsupportedClassVersionError 로 죽는다.
        XCTAssertEqual(VersionRules.javaMajor("1.20.4"), 17)
        XCTAssertEqual(VersionRules.javaMajor("1.20.6"), 21)
        XCTAssertEqual(VersionRules.javaMajor("1.21.4"), 21)
    }

    /// ⚠️ 힙 천장이 jetsam 예산과 같으면 아틀라스(NativeImage — 힙 밖)가 쓸 자리가 0 이
    /// 되는 설정을 고를 수 있다. 실측으로 그렇게 죽었다 — 슬라이더가 그걸 못 고르게 한다.
    func testHeapCeilingLeavesRoomForOffHeap() {
        let budget = JvmSettingsStore.jetsamBudgetMb
        let ceiling = JvmSettingsStore.maxHeapCeilingMb
        XCTAssertGreaterThan(budget, 0)
        // 힙 밖(아틀라스·렌더러·JVM)이 쓸 자리를 반드시 남겨야 한다.
        XCTAssertLessThanOrEqual(ceiling, budget - JvmSettingsStore.offHeapFloorMb,
                                 "힙 천장이 힙 밖 몫을 먹으면 반드시 jetsam 으로 죽는다")
        // 기본값은 천장 안에 있어야 한다 — 아니면 로드할 때마다 되돌려진다.
        XCTAssertLessThanOrEqual(JvmSettings().maxHeapMb, ceiling)
    }

    /// ⚠️ 힙이 1.5 GB 로 묶인 iOS 에서 young 20% + 예비 20% 는 **힙의 40%** 를
    /// 상주 객체에 못 쓰게 만든다 — 실제로 Full GC 무한 반복으로 게임이 섰다.
    func testG1LeavesRoomForLiveData() {
        let args = JvmSettings().jvmArgs(
            instanceDir: Paths.instance("t"), userDir: "/tmp", libraryPath: "/lib",
            mainClass: "Main", javaMajor: 21, renderer: .mobileglues,
            screenSize: (1920, 1080))
        func percent(_ flag: String) -> Int? {
            args.first { $0.hasPrefix("-XX:\(flag)=") }
                .flatMap { Int($0.split(separator: "=").last ?? "") }
        }
        let young = percent("G1NewSizePercent") ?? 0
        let reserve = percent("G1ReservePercent") ?? 0
        XCTAssertLessThanOrEqual(young + reserve, 20,
                                 "young+예비가 힙의 20% 를 넘으면 상주 데이터가 들어갈 자리가 없다")
    }

    /// ⚠️ 미러 코드 캐시는 **OS 버전이 아니라 실제 능력**으로 켜야 한다. 같은 iOS 26 이어도
    /// 실행 가능 메모리를 그냥 얻을 수 있는 환경(맥의 'Designed for iPad')에서는 필요 없고,
    /// 그런데도 주면 libjvm 이 없는 디버거를 기다리며 선다.
    func testMirroredCodeCacheFollowsCapabilityNotOSVersion() {
        let args = JvmSettings().jvmArgs(
            instanceDir: Paths.instance("t"), userDir: "/tmp", libraryPath: "/lib",
            mainClass: "Main", javaMajor: 21, renderer: .mobileglues,
            screenSize: (1920, 1080))
        let asked = args.contains("-XX:+MirrorMappedCodeCache")
        let needed = FlameNativeHasJITFlags([.forceMirrored, .hasTXM])
        XCTAssertEqual(asked, needed,
                       "미러 코드 캐시 플래그가 실제 JIT 능력과 어긋난다")

        // ⚠️ libjvm 이 dlsym 으로 읽는 DeviceHasTXM 도 **같은 답**이어야 한다.
        //    어긋나면 "TXM 이라 했는데 미러는 없는" 상태가 되어 코드 캐시 메타데이터를
        //    읽다 SIGSEGV(PcDescCache::add_pc_desc) 로 죽는다 — 맥에서 실제로 그랬다.
        XCTAssertEqual(DeviceHasTXM(), needed,
                       "DeviceHasTXM 과 MirrorMappedCodeCache 조건이 어긋난다")

    }

    /// 1.7.2 이하는 에셋을 해시 폴더가 아니라 이름으로 찾는다 — 옛 배치가 없으면
    /// 1.6~1.7.2 는 글자가 번역 키로, 1.5.2 이하는 소리 없이 뜬다.
    func testLegacyAssetsAreLaidOutByName() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "legacy-assets-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let object = dir.appending(path: "assets/objects/01/\(hash)")
        try fm.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("en".utf8).write(to: object)
        let index = dir.appending(path: "assets/indexes/pre-1.6.json")
        try fm.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"map_to_resources":true,"objects":{"lang/en_US.lang":{"hash":"\#(hash)","size":2}}}"#.utf8)
            .write(to: index)

        let root = GameLauncher.prepareLegacyAssets(instanceDir: dir, indexId: "pre-1.6")
        XCTAssertEqual(root?.lastPathComponent, "pre-1.6")
        XCTAssertTrue(fm.fileExists(atPath: dir.appending(path: "assets/virtual/pre-1.6/lang/en_US.lang").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appending(path: "resources/lang/en_US.lang").path))
        // 요즘 인덱스(virtual 아님)는 건드리지 않는다.
        XCTAssertNil(GameLauncher.prepareLegacyAssets(instanceDir: dir, indexId: "없음"))
    }

    // MARK: - JVM 인자

    /// JRE9+ 에 `-Xbootclasspath/p:` 가 들어가면 JNI_CreateJavaVM 이 -6 으로 거부한다.
    func testJvmArgsCacioSplit() {
        let settings = JvmSettings()
        func args(_ javaMajor: Int) -> [String] {
            settings.jvmArgs(
                instanceDir: Paths.instance("t"), userDir: "/tmp",
                libraryPath: "/lib", mainClass: "Main", javaMajor: javaMajor,
                renderer: .zink, screenSize: (1920, 1080)
            )
        }
        XCTAssertTrue(args(8).contains { $0.hasPrefix("-Xbootclasspath/p:") })
        XCTAssertFalse(args(21).contains { $0.hasPrefix("-Xbootclasspath/p:") })
        XCTAssertTrue(args(21).contains { $0.hasPrefix("-Xbootclasspath/a:") })

        // Java 8 은 모르는 옵션 하나에 JVM 생성을 통째로 거부한다 — 1.16 이하가 전부 죽던 원인.
        let java8 = args(8)
        for jdk9Only in ["-Xlog", "-XX:G1PeriodicGC", "-XX:+G1PeriodicGC", "--add-"] {
            XCTAssertFalse(java8.contains { $0.hasPrefix(jdk9Only) }, "Java 8 이 모르는 옵션: \(jdk9Only)")
        }

        // 렌더러 libname 은 **JVM 인자로도** 내보내야 한다. 네이티브 브릿지가
        // System.setProperty 로 심기는 하지만 org.lwjgl.opengl.GL 이 먼저 <clinit> 되면
        // 그 시점 값으로 굳어버려서 "Core OpenGL functions could not be found" 가 났다.
        XCTAssertTrue(args(21).contains("-Dorg.lwjgl.opengl.libname=\(Renderer.zink.libName)"))

        // 클래스패스는 JLI_Launch 에 -cp 로 넘긴다 — -D 로 중복 지정하지 않는다.
        XCTAssertFalse(args(21).contains { $0.hasPrefix("-Djava.class.path") })

        // toRealPath 를 살리는 에이전트가 반드시 붙어야 한다 — 빠지면 Cobblemon 같은
        // 모드가 "Invalid CommonJS root folder" 로 죽는다.
        XCTAssertTrue(args(21).contains { $0.hasSuffix("libs/flame_bootstrap.jar") },
                      "IosFsAgent 가 -javaagent 로 붙지 않았습니다")

        // iOS 전용: 메인 스레드를 JVM 에 못 주므로 LWJGL 의 첫-스레드 검사를 꺼야 한다.
        XCTAssertTrue(args(21).contains("-Dorg.lwjgl.glfw.checkThread0=false"))
        XCTAssertTrue(args(21).contains("-XX:+DisablePrimordialThreadGuardPages"))
    }

    /// 렌더러 dylib 이름은 네이티브(flame_environ.h 의 RENDERER_NAME_*)와 같아야 한다.
    /// 어긋나면 dlopen 이 조용히 실패하고 게임이 검은 화면으로 뜬다.
    func testRendererLibNamesMatchNative() {
        XCTAssertEqual(Renderer.gl4es.libName, "libgl4es_114.dylib")
        XCTAssertEqual(Renderer.zink.libName, "libOSMesa.8.dylib")
        XCTAssertEqual(Renderer.mobileglues.libName, "libmobileglues.dylib")
        // 기본 렌더러이자 목록 첫 번째 — GL 구현이 가장 넓고 Zink 보다 훨씬 가볍다.
        XCTAssertEqual(Renderer.allCases.first, .mobileglues)
        XCTAssertEqual(RendererStore.load(), .mobileglues)
        // OSMesa 만 CGImage 로 올리므로 CAMetalLayer 를 쓰지 않는다.
        XCTAssertFalse(Renderer.zink.usesMetalLayer)
        XCTAssertTrue(Renderer.gl4es.usesMetalLayer)
        XCTAssertTrue(Renderer.mobileglues.usesMetalLayer)

        // 번들에 실제로 들어가는지 — 이름만 맞고 파일이 없으면 dlopen 이 조용히 실패한다.
        for renderer in Renderer.allCases {
            let path = Bundle.main.bundleURL.appending(path: "Frameworks/\(renderer.libName)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                          "번들에 \(renderer.libName) 이 없습니다")
        }
    }

    /// pre-1.13 은 Zink 로 못 돌아서 GL4ES 로 강제된다.
    func testRendererResolutionForLegacy() {
        var meta = InstanceMeta(id: "t", name: "t", type: .vanilla, mcVersion: "1.12.2")
        meta.rendererId = Renderer.zink.rawValue
        XCTAssertEqual(RendererStore.resolve(for: meta), .gl4es)

        meta.mcVersion = "1.21.4"
        XCTAssertEqual(RendererStore.resolve(for: meta), .zink)
    }

    /// 고를 수 있는 렌더러는 셋뿐이다. MetalANGLE 은 MobileGlues 의 부분집합이라 뺐다.
    func testRendererCatalog() {
        XCTAssertEqual(Renderer.allCases, [.mobileglues, .gl4es, .zink])
        XCTAssertNil(Renderer(rawValue: "angle"))
    }

    /// 탭과 롱프레스는 **서로 다른 버튼**이어야 한다.
    /// 같게 두면 일반 모드에서 우클릭이 안 나가 음식을 먹을 수 없다(실제 버그였다).
    /// 26.3+(SDL3)는 키를 SDL 스캔코드로만 받는다 — 화면 버튼이 틀린 값으로 가면 먹통이다.
    /// 기대값은 26.3 클라이언트의 `InputConstants` 상수를 javap 로 옮긴 것이다.
    func testSdlScancodeMatchesMinecraft263() {
        XCTAssertEqual(GlfwKeys.sdlScancode(for: 87), 26)                     // KEY_W
        XCTAssertEqual(GlfwKeys.sdlScancode(for: GlfwKeys.a), 4)              // KEY_A
        XCTAssertEqual(GlfwKeys.sdlScancode(for: 49), 30)                     // KEY_1
        XCTAssertEqual(GlfwKeys.sdlScancode(for: GlfwKeys.space), 44)         // KEY_SPACE
        XCTAssertEqual(GlfwKeys.sdlScancode(for: GlfwKeys.escape), 41)        // KEY_ESCAPE
        XCTAssertEqual(GlfwKeys.sdlScancode(for: GlfwKeys.enter), 40)         // KEY_RETURN
        XCTAssertEqual(GlfwKeys.sdlScancode(for: GlfwKeys.backspace), 42)     // KEY_BACKSPACE
        XCTAssertEqual(GlfwKeys.sdlScancode(for: GlfwKeys.leftShift), 225)    // KEY_LSHIFT
        XCTAssertEqual(GlfwKeys.sdlScancode(for: GlfwKeys.leftControl), 224)  // KEY_LCONTROL
        XCTAssertEqual(GlfwKeys.sdlScancode(for: GlfwKeys.f1 + 2), 60)        // KEY_F3
        XCTAssertEqual(GlfwKeys.sdlScancode(for: -1), 0)
    }

    func testTouchButtonMapping() {
        // 일반 모드 — 탭은 우클릭(놓기), 길게는 좌클릭 유지(채굴)
        XCTAssertEqual(TouchButton.tap(combatMode: false, grabbing: true), GlfwKeys.mouseRight)
        XCTAssertEqual(TouchButton.hold(combatMode: false, grabbing: true), GlfwKeys.mouseLeft)

        // 전투 모드 — 탭은 좌클릭(공격), 길게는 우클릭 유지(방패·활·먹기)
        XCTAssertEqual(TouchButton.tap(combatMode: true, grabbing: true), GlfwKeys.mouseLeft)
        XCTAssertEqual(TouchButton.hold(combatMode: true, grabbing: true), GlfwKeys.mouseRight)

        // 어느 모드든 탭과 길게는 달라야 한다.
        for combat in [false, true] {
            XCTAssertNotEqual(TouchButton.tap(combatMode: combat, grabbing: true),
                              TouchButton.hold(combatMode: combat, grabbing: true))
        }

        // 메뉴·인벤토리(grab 아님)는 언제나 좌클릭 — GUI 는 우클릭에 반응하지 않는다.
        for combat in [false, true] {
            XCTAssertEqual(TouchButton.tap(combatMode: combat, grabbing: false), GlfwKeys.mouseLeft)
            XCTAssertEqual(TouchButton.hold(combatMode: combat, grabbing: false), GlfwKeys.mouseLeft)
        }
    }

    /// NeoForge 의 jvm 인자는 **플래그와 값이 따로 떨어진 원소**다.
    /// 값만 버리면 앞 플래그가 다음 인자를 값으로 삼켜 JVM 이 부팅 전에 죽는다
    /// ("Error: -p requires module path specification" — 실제로 그랬다).
    func testLoaderJvmArgExpansion() {
        let dir = URL(fileURLWithPath: "/tmp/inst")
        let args = [
            "-DignoreList=client-extra,${version_name}.jar",
            "-DlibraryDirectory=${library_directory}",
            "-p",
            "${library_directory}/a.jar${classpath_separator}${library_directory}/b.jar",
            "--add-modules",
            "ALL-MODULE-PATH",
        ]
        let out = GameLauncher.expandLoaderJvmArgs(args, instanceDir: dir, mcVersion: "1.21.4")

        XCTAssertEqual(out, [
            "-DignoreList=client-extra,1.21.4.jar",
            "-DlibraryDirectory=/tmp/inst/libraries",
            "-p",
            "/tmp/inst/libraries/a.jar:/tmp/inst/libraries/b.jar",
            "--add-modules",
            "ALL-MODULE-PATH",
        ])
        // -p 뒤에는 반드시 값이 와야 한다.
        XCTAssertEqual(out.firstIndex(of: "-p").map { out[out.index(after: $0)] },
                       "/tmp/inst/libraries/a.jar:/tmp/inst/libraries/b.jar")
    }

    /// 채울 수 없는 자리표시자는 **플래그까지 같이** 버려야 한다.
    func testUnknownPlaceholderDropsItsFlag() {
        let out = GameLauncher.expandLoaderJvmArgs(
            ["-p", "${something_we_do_not_know}", "--add-modules", "ALL-MODULE-PATH"],
            instanceDir: URL(fileURLWithPath: "/tmp/inst"), mcVersion: "1.21.4")
        XCTAssertEqual(out, ["--add-modules", "ALL-MODULE-PATH"])
        XCTAssertFalse(out.contains("-p"))
    }

    /// 모듈 경로에 올린 jar 은 클래스패스에서 빠져야 한다.
    /// 둘 다 있으면 클래스가 두 로더에 생겨 --add-opens 가 엉뚱한 쪽에만 적용된다.
    func testModulePathEntriesAreCollected() {
        let args = ["-p", "/libs/a.jar:/libs/b.jar", "--add-modules", "ALL-MODULE-PATH"]
        XCTAssertEqual(GameLauncher.modulePathEntries(args), ["/libs/a.jar", "/libs/b.jar"])

        // 값이 없는 꼬리 -p 는 무시한다(범위 초과로 죽으면 안 된다).
        XCTAssertTrue(GameLauncher.modulePathEntries(["-p"]).isEmpty)
        XCTAssertTrue(GameLauncher.modulePathEntries([]).isEmpty)
    }

    /// 계획의 `--output` 은 프로세서 산출물이다 — 게임 클래스패스에서 빠져야 한다.
    /// neoforge-*-client.jar 이 남아 `minecraft` 모듈과 패키지가 겹쳐 부팅이 막혔다.
    func testPlanOutputsAreCollected() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "planout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan: [String: Any] = ["steps": [
            ["jar": "a.jar", "classpath": [], "args": ["--input", "x.jar", "--output", "libraries/out1.jar"]],
            ["jar": "b.jar", "classpath": [], "args": ["--out", "libraries/out2.jar"]],
            ["jar": "c.jar", "classpath": [], "args": ["--output"]],   // 값 없음 — 무시
        ]]
        try JSONSerialization.data(withJSONObject: plan)
            .write(to: dir.appending(path: ForgeInstallPlanner.planFileName))

        XCTAssertEqual(ForgeInstallPlanner.outputPaths(instanceDir: dir),
                       ["libraries/out1.jar", "libraries/out2.jar"])
        // 계획이 없는 인스턴스는 빈 집합.
        XCTAssertTrue(ForgeInstallPlanner.outputPaths(
            instanceDir: URL(fileURLWithPath: "/nonexistent")).isEmpty)
    }

    /// 설치 중간 산출물은 클래스패스에서 빠져야 한다.
    /// 남으면 `client` 자동 모듈이 되어 `minecraft` 모듈과 패키지가 겹친다.
    func testLoaderIntermediateJarsAreExcluded() {
        let base = "/inst/libraries/net/minecraft/client/1.21.4-20241203.161809/"
        for name in ["client-1.21.4-20241203.161809-slim.jar",
                     "client-1.21.4-20241203.161809-srg.jar"] {
            XCTAssertTrue(GameLauncher.isLoaderIntermediateJar(base + name), name)
        }
        // -extra 는 NeoForge 가 ignoreList 로 직접 건너뛴다 — 우리가 빼면 안 된다.
        XCTAssertFalse(GameLauncher.isLoaderIntermediateJar(
            base + "client-1.21.4-20241203.161809-extra.jar"))
        // 진짜 게임 jar 과 일반 라이브러리는 건드리지 않는다.
        XCTAssertFalse(GameLauncher.isLoaderIntermediateJar(
            "/inst/libraries/net/neoforged/neoforge/21.4.157/neoforge-21.4.157-client.jar"))
        XCTAssertFalse(GameLauncher.isLoaderIntermediateJar(
            "/inst/libraries/org/ow2/asm/asm/9.8/asm-9.8.jar"))
    }

    /// 같은 모듈의 **다른 버전**도 걸러야 한다.
    /// asm 9.8 이 모듈 경로에 있는데 9.6 이 클래스패스에 남아 BootstrapLauncher 가 죽었다.
    func testArtifactKeyIgnoresVersion() {
        let base = "/inst/libraries/org/ow2/asm/asm"
        XCTAssertEqual(GameLauncher.artifactKey("\(base)/9.8/asm-9.8.jar"), base)
        XCTAssertEqual(GameLauncher.artifactKey("\(base)/9.6/asm-9.6.jar"), base)
        // 다른 아티팩트는 달라야 한다.
        XCTAssertNotEqual(
            GameLauncher.artifactKey("/inst/libraries/org/ow2/asm/asm-tree/9.8/asm-tree-9.8.jar"),
            base)
    }

    /// 로더와 바닐라가 받은 **다른 버전**은 한 벌로 합치되, 분류자가 다르면 따로 남긴다.
    /// failureaccess 1.0.1 · 1.0.2 가 함께 올라가 Forge 1.21.4 모듈 해석이 막혔다.
    func testLibraryKeyMergesVersionsButKeepsClassifiers() {
        let lib = "/inst/libraries"
        XCTAssertEqual(
            GameLauncher.libraryKey("\(lib)/com/google/guava/failureaccess/1.0.1/failureaccess-1.0.1.jar"),
            GameLauncher.libraryKey("\(lib)/com/google/guava/failureaccess/1.0.2/failureaccess-1.0.2.jar"))
        XCTAssertEqual(
            GameLauncher.libraryKey("\(lib)/com/google/guava/guava/32.1.2-jre/guava-32.1.2-jre.jar"),
            GameLauncher.libraryKey("\(lib)/com/google/guava/guava/33.3.1-jre/guava-33.3.1-jre.jar"))
        XCTAssertNotEqual(
            GameLauncher.libraryKey("\(lib)/net/minecraftforge/forge/1.21.4-54.1.14/forge-1.21.4-54.1.14-client.jar"),
            GameLauncher.libraryKey("\(lib)/net/minecraftforge/forge/1.21.4-54.1.14/forge-1.21.4-54.1.14-universal.jar"))
        // Maven 배치가 아니면 건드리지 않는다.
        XCTAssertEqual(GameLauncher.libraryKey("/app/libs/lwjgl.jar"), "/app/libs/lwjgl.jar")
        XCTAssertEqual(GameLauncher.libraryKey("/inst/versions/1.21.4/1.21.4.jar"),
                       "/inst/versions/1.21.4/1.21.4.jar")
    }

    /// 요구 버전에 못 미치면 **낮은 JRE 를 떠넘기지 않는다.**
    /// 예전에는 그래서 MC 26.2(Java 25)가 Java 21 로 떠 UnsupportedClassVersionError 로 죽었다.
    func testJavaSelectionRefusesTooOldRuntime() {
        func install(_ major: Int) -> JavaInstall {
            JavaInstall(name: "java-\(major)-openjdk",
                        home: URL(fileURLWithPath: "/j/\(major)"), majorVersion: major)
        }
        let have = [install(8), install(17), install(21)]

        // 필요 이상으로 높은 걸 고르지 않는다 — 구버전이 모듈 캡슐화에 걸린다.
        XCTAssertEqual(JavaInstallStore.select(minVersion: 8, from: have)?.majorVersion, 8)
        XCTAssertEqual(JavaInstallStore.select(minVersion: 17, from: have)?.majorVersion, 17)
        XCTAssertEqual(JavaInstallStore.select(minVersion: 21, from: have)?.majorVersion, 21)

        // 25 가 필요한데 없으면 nil — 호출자가 "Java 25 가 필요합니다"를 띄운다.
        XCTAssertNil(JavaInstallStore.select(minVersion: 25, from: have))
        XCTAssertNil(JavaInstallStore.select(minVersion: 21, from: []))

        // 25 가 있으면 고른다.
        XCTAssertEqual(
            JavaInstallStore.select(minVersion: 25, from: have + [install(25)])?.majorVersion, 25)
    }

    /// LWJGL 네이티브 추출 경로는 **쓸 수 있는 곳**이어야 한다.
    /// 앱 번들 Frameworks/ 를 가리켰다가 MC 26.2 가 버전 폴더를 못 만들고 죽었다.
    func testLwjglExtractPathIsWritable() {
        let dir = URL(fileURLWithPath: "/inst")
        let bundleFrameworks = Bundle.main.bundleURL.appending(path: "Frameworks").path
        let args = JvmSettings().jvmArgs(
            instanceDir: dir, userDir: dir.path, libraryPath: bundleFrameworks,
            mainClass: "net.minecraft.client.main.Main", javaMajor: 25,
            renderer: .mobileglues, screenSize: (800, 600))

        let extract = args.filter { $0.hasPrefix("-Dorg.lwjgl.system.SharedLibraryExtract") }
        XCTAssertEqual(extract.count, 2)
        for arg in extract {
            let path = String(arg.split(separator: "=", maxSplits: 1)[1])
            XCTAssertTrue(path.hasPrefix(Paths.caches.path), "쓰기 가능한 캐시여야 한다: \(arg)")
            XCTAssertFalse(path.hasPrefix(Bundle.main.bundleURL.path), "번들은 읽기 전용이다: \(arg)")
        }
        // 찾는 경로는 그대로 번들이어야 한다 — 우리 dylib 이 거기 있다.
        XCTAssertTrue(args.contains("-Dorg.lwjgl.librarypath=\(bundleFrameworks)"))
    }

    /// 바닐라 LWJGL jar 은 **전부** 빠져야 한다.
    /// 일부만 남기면 그 모듈이 `requires org.lwjgl` 인데 코어가 없어 NeoForge 가 깨진다.
    func testVanillaLwjglJarsAreAllDropped() {
        for name in ["lwjgl.jar", "lwjgl-3.4.1.jar", "lwjgl-opengl-3.4.1.jar",
                     "lwjgl-jemalloc-3.4.1.jar", "lwjgl-spvc-3.4.1.jar",
                     "lwjgl-glfw-3.4.1-natives-macos.jar"] {
            XCTAssertTrue(GameLauncher.shouldDropVanillaLwjgl(name), name)
        }
        // lwjgl 과 무관한 jar 은 건드리지 않는다.
        for name in ["guava-33.3.1-jre.jar", "asm-9.8.jar", "joml-1.10.8.jar"] {
            XCTAssertFalse(GameLauncher.shouldDropVanillaLwjgl(name), name)
        }
    }

    /// 계획을 새로 쓰면 "이미 돌렸음" 표시가 지워져야 한다 — 새 계획은 다시 돌아야 한다.
    func testPlanRewriteClearsDoneMarker() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "plandone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let done = dir.appending(path: ForgeInstallPlanner.doneFileName)
        try Data("1".utf8).write(to: done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path))

        let planner = ForgeInstallPlanner(
            instanceDir: dir, installerJar: dir.appending(path: "i.jar"),
            extracted: dir, mcVersion: "1.21.6", onProgress: { _ in })
        try await0 { try await planner.write(profile: [:], processors: [], gameJars: []) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: done.path),
                       "계획을 다시 쓰면 표시가 남아 있으면 안 된다")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appending(path: ForgeInstallPlanner.planFileName).path))
    }

    /// 비동기 호출을 동기 테스트에서 기다린다.
    private func await0(_ body: @escaping () async throws -> Void) rethrows {
        let done = expectation(description: "async")
        Task { try? await body(); done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    /// 의존성은 **필수만** 따라간다.
    /// 선택까지 끌어오면 안 쓰는 모드가 쌓이고, 비호환을 잘못 읽으면 충돌 모드를 깐다.
    func testOnlyRequiredDependenciesAreCarried() throws {
        // Modrinth: dependency_type 이 "required" 인 것만
        let modrinth = """
        [{"id":"v1","name":"1.0","game_versions":["1.21.6"],"loaders":["neoforge"],
          "files":[{"url":"https://x/a.jar","filename":"a.jar","primary":true}],
          "dependencies":[
            {"project_id":"need-me","dependency_type":"required"},
            {"project_id":"skip-optional","dependency_type":"optional"},
            {"project_id":"skip-embedded","dependency_type":"embedded"},
            {"project_id":"skip-bad","dependency_type":"incompatible"},
            {"project_id":null,"dependency_type":"required"}]}]
        """
        struct MRVersion: Decodable {
            struct File: Decodable { let url: String; let filename: String; let primary: Bool }
            struct Dependency: Decodable { let project_id: String?; let dependency_type: String }
            let dependencies: [Dependency]?
        }
        let parsed = try JSONDecoder().decode([MRVersion].self, from: Data(modrinth.utf8))
        let required = (parsed[0].dependencies ?? [])
            .filter { $0.dependency_type == "required" }
            .compactMap(\.project_id)
        XCTAssertEqual(required, ["need-me"], "필수만, 그리고 project_id 가 없는 건 버린다")

        // CurseForge: relationType 3 만
        struct CFDep: Decodable { let modId: Int; let relationType: Int }
        let cf = try JSONDecoder().decode([CFDep].self, from: Data("""
        [{"modId":111,"relationType":3},{"modId":222,"relationType":2},
         {"modId":333,"relationType":5},{"modId":444,"relationType":6}]
        """.utf8))
        XCTAssertEqual(cf.filter { $0.relationType == 3 }.map(\.modId), [111])
    }

    // MARK: - 조이스틱 8방위

    func testJoystickQuantization() {
        // 화면 좌표계라 위쪽이 -y.
        XCTAssertEqual(Joystick.keys(forAngle: 0), [68])                 // →  D
        XCTAssertEqual(Joystick.keys(forAngle: .pi / 2), [83])           // ↓  S
        XCTAssertEqual(Joystick.keys(forAngle: -.pi / 2), [87])          // ↑  W
        XCTAssertEqual(Joystick.keys(forAngle: .pi), [65])               // ←  A
        XCTAssertEqual(Joystick.keys(forAngle: -.pi / 4), [87, 68])      // ↗  W+D
    }

    // MARK: - GLFW 키 매핑

    func testGlfwKeyMapping() {
        XCTAssertEqual(GlfwKeys.fromHID(.keyboardW), 87)
        XCTAssertEqual(GlfwKeys.fromHID(.keyboardZ), 90)
        XCTAssertEqual(GlfwKeys.fromHID(.keyboard0), 48)
        XCTAssertEqual(GlfwKeys.fromHID(.keyboard5), 53)
        XCTAssertEqual(GlfwKeys.fromHID(.keyboardF3), 292)
        XCTAssertEqual(GlfwKeys.fromHID(.keyboardEscape), 256)
        XCTAssertEqual(GlfwKeys.fromHID(.keyboardLeftShift), 340)
        XCTAssertNil(GlfwKeys.fromHID(.keyboardVolumeUp))
    }

    // MARK: - 로그인

    /// XSTS 는 거절 사유를 본문의 XErr 코드로만 준다. 매핑이 깨지면 사용자는
    /// "요청 실패 (401)" 만 보게 되는데, 실제로는 대부분 안내 가능한 계정 문제다.
    func testXstsErrorMessages() {
        func message(_ xerr: Int64) -> String {
            let body = try! JSONSerialization.data(withJSONObject: ["XErr": xerr])
            return AuthStore.xstsMessage(for: .init(code: 401, url: "x", body: body))
        }
        XCTAssertTrue(message(2_148_916_233).contains("Xbox 프로필이 없습니다"))
        XCTAssertTrue(message(2_148_916_235).contains("국가/지역"))
        XCTAssertTrue(message(2_148_916_236).contains("성인 인증"))
        XCTAssertTrue(message(2_148_916_237).contains("성인 인증"))
        XCTAssertTrue(message(2_148_916_238).contains("미성년자"))
        // 모르는 코드도 코드값은 보여줘야 검색이라도 할 수 있다.
        XCTAssertTrue(message(2_148_916_299).contains("2148916299"))

        // 본문이 JSON 이 아닐 때도 죽지 않아야 한다.
        let garbage = AuthStore.xstsMessage(for: .init(code: 401, url: "x", body: Data("nope".utf8)))
        XCTAssertTrue(garbage.contains("알 수 없음"))
    }

    /// 스코프와 RpsTicket 접두사는 한 쌍이다. `XboxLive.signin` 은 `d=` 가 필요하고
    /// 레거시 `MBI_SSL` 은 붙이면 안 된다 — 어긋나면 XBL 인증이 조용히 실패한다.
    ///
    /// 리디렉션이 https 라 WKWebView 로 가로채야 한다는 점도 여기서 고정한다.
    /// (ASWebAuthenticationSession 으로 되돌리면 로그인이 영영 안 끝난다)
    func testAuthFlowParameters() {
        XCTAssertEqual(AuthStore.scope, "XboxLive.signin offline_access")
        XCTAssertTrue(AuthStore.redirectURI.hasPrefix("https://"),
                      "https 리디렉션이면 커스텀 스킴 콜백을 쓸 수 없다")
    }

    /// 로그인이 끝나면 리디렉션 URL 에 결과가 실려 온다. 이 파싱이 깨지면
    /// "로그인 정보를 받을 수 없음" 으로만 보인다.
    @MainActor
    func testRedirectParsing() throws {
        func parse(_ query: String) -> Result<String, Error> {
            MicrosoftLoginController.parse(
                redirect: URL(string: "https://login.live.com/oauth20_desktop.srf?\(query)")!)
        }

        XCTAssertEqual(try parse("code=M.C123_BAY.2.U.abc").get(), "M.C123_BAY.2.U.abc")

        // 거절은 취소와 같게 — 오류 알림을 띄우면 안 된다.
        if case .failure(let error) = parse("error=access_denied&error_description=nope") {
            XCTAssertEqual(error as? AuthStore.AuthError, .cancelled)
        } else { XCTFail("거절을 취소로 처리해야 합니다") }

        // 그 외 오류는 서버가 준 설명을 그대로 보여준다.
        if case .failure(let error) = parse("error=invalid_scope&error_description=bad%20scope") {
            XCTAssertTrue(error.localizedDescription.contains("bad scope"))
        } else { XCTFail("오류를 전달해야 합니다") }

        // code 도 error 도 없으면 실패로 친다(빈 code 포함).
        XCTAssertThrowsError(try parse("code=").get())
        XCTAssertThrowsError(try parse("").get())
    }

    /// 만료 판정은 epoch **밀리초** 기준이다 — 초로 착각하면 항상 만료로 보여
    /// 매번 재로그인을 요구하게 된다.
    func testSessionExpiry() {
        let now = Date().timeIntervalSince1970 * 1000
        func session(expiresAt: Double) -> AuthSession {
            AuthSession(username: "a", uuid: "b", accessToken: "c",
                        refreshToken: "d", expiresAt: expiresAt)
        }
        XCTAssertTrue(session(expiresAt: now + 3_600_000).isValid)
        XCTAssertFalse(session(expiresAt: now - 1000).isValid)
        // 만료 1분 전부터는 갱신하러 간다(요청 도중에 만료되는 것 방지).
        XCTAssertFalse(session(expiresAt: now + 30_000).isValid)
    }

    /// 토큰은 파일이 아니라 키체인에 넣는다.
    func testKeychainRoundTrip() throws {
        let service = "flamelauncher.test", account = "roundtrip-\(UUID().uuidString)"
        defer { Keychain.delete(service: service, account: account) }

        XCTAssertNil(Keychain.load(service: service, account: account))
        Keychain.save(Data("secret".utf8), service: service, account: account)
        XCTAssertEqual(Keychain.load(service: service, account: account), Data("secret".utf8))

        // 같은 키에 다시 쓰면 덮어써야 한다(중복 항목이 쌓이면 조회가 엉킨다).
        Keychain.save(Data("updated".utf8), service: service, account: account)
        XCTAssertEqual(Keychain.load(service: service, account: account), Data("updated".utf8))

        Keychain.delete(service: service, account: account)
        XCTAssertNil(Keychain.load(service: service, account: account))
    }

    /// 폼 본문에서 `+` 는 공백을 뜻한다. 퍼센트 인코딩을 안 하면 토큰에 `+` 가 든 계정만
    /// 로그인이 실패해서 원인을 찾기 어렵다.
    func testFormEncodingEscapesReservedCharacters() {
        let encoded = HTTP.formEncoded(["code": "a+b/c=d&e f"])
        XCTAssertEqual(encoded, "code=a%2Bb%2Fc%3Dd%26e%20f")

        // 스코프의 콜론도 그대로 나가면 안 된다.
        XCTAssertEqual(HTTP.formEncoded(["scope": "service::user.auth.xboxlive.com::MBI_SSL"]),
                       "scope=service%3A%3Auser.auth.xboxlive.com%3A%3AMBI_SSL")
    }

    // MARK: - 실행 차단

    /// 번들 JRE·렌더러는 기기용 arm64(iOS) 바이너리다. 시뮬레이터에서 dlopen 하면
    /// 코드서명 검증에 걸려 **프로세스가 SIGKILL 로 죽는다**(잡을 수 있는 예외가 아니다).
    /// 그래서 시도 자체를 막아야 하고, 그 판정이 사라지면 다시 크래시한다.
    func testSimulatorCannotRunGame() throws {
        #if targetEnvironment(simulator)
        XCTAssertFalse(NativeJavaRuntime.isReady, "시뮬레이터에서는 네이티브 런타임을 쓰면 안 된다")
        XCTAssertTrue(NativeJavaRuntime.missingPieces.contains { $0.contains("시뮬레이터") })
        XCTAssertFalse(GameRuntime.current.isAvailable)
        #else
        throw XCTSkip("기기에서는 실제 실행이 가능하다")
        #endif
    }

    /// 네이티브 실패 코드는 사유로 번역돼야 한다 — 안 그러면 "코드 -3 으로 종료" 만 보인다.
    func testLaunchFailureReasons() {
        XCTAssertNotNil(NativeJavaRuntime.launchFailureReason(Int32(FLAME_LAUNCH_ERR_SIMULATOR)))
        XCTAssertNotNil(NativeJavaRuntime.launchFailureReason(Int32(FLAME_LAUNCH_ERR_NO_JLI)))
        XCTAssertNotNil(NativeJavaRuntime.launchFailureReason(Int32(FLAME_LAUNCH_ERR_DLOPEN)))
        XCTAssertNotNil(NativeJavaRuntime.launchFailureReason(Int32(FLAME_LAUNCH_ERR_NO_SYMBOL)))
        // 0 이상은 JVM 이 그 코드로 종료한 것이지 실행 실패가 아니다.
        XCTAssertNil(NativeJavaRuntime.launchFailureReason(0))
        XCTAssertNil(NativeJavaRuntime.launchFailureReason(1))
    }

    // MARK: - JIT

    /// 시뮬레이터는 코드서명 강제가 없어 JIT 제한도 없다 — "켜짐"으로 나와야 게이트가
    /// 시뮬레이터에서 게임 실행을 막지 않는다.
    ///
    /// 그리고 탈옥으로 오판하면 안 된다. 시뮬레이터에서는 호스트 맥의 `/Applications` 가
    /// 보여서, Pojav 의 마지막 판정(디렉터리 접근 가능 = 탈옥)을 그대로 두면 통과해 버린다.
    func testJITStateOnSimulator() throws {
        #if targetEnvironment(simulator)
        XCTAssertTrue(FlameNativeIsJITEnabled())
        XCTAssertFalse(FlameNativeIsJailbroken())
        XCTAssertEqual(FlameNativeInstallType(), "Simulator")
        #else
        throw XCTSkip("기기에서는 서명 상태에 따라 달라진다")
        #endif
    }

    /// 진단 문자열은 게이트 화면에 그대로 나가므로 항목이 빠지면 바로 티가 난다.
    func testDiagnosticsCoversEveryGate() {
        let text = FlameNativeDiagnostics()
        for key in ["설치 유형", "JIT", "get-task-allow", "TrollStore JIT",
                    "AltServer 연동", "확장 가상 주소", "물리 메모리"] {
            XCTAssertTrue(text.contains(key), "진단에 '\(key)' 가 없습니다")
        }
    }

    // MARK: - JRE 탐색

    /// `release` 파일의 JAVA_VERSION 파싱. 8("1.8.0_312")과 17("17.0.9")의 표기가 달라
    /// 여기서 틀리면 cacio 주입 방식이 어긋나 JVM 이 아예 안 뜬다.
    func testJavaMajorVersionParsing() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "runtimes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func makeRuntime(_ name: String, release: String?) throws -> URL {
            let dir = root.appending(path: name)
            try FileManager.default.createDirectory(at: dir.appending(path: "lib"),
                                                    withIntermediateDirectories: true)
            // isUsable 판정을 통과시키기 위한 더미 libjli
            try Data().write(to: dir.appending(path: "lib/libjli.dylib"))
            if let release {
                try release.write(to: dir.appending(path: "release"),
                                  atomically: true, encoding: .utf8)
            }
            return dir
        }

        _ = try makeRuntime("java-8", release: "JAVA_VERSION=\"1.8.0_312\"\nOS_NAME=\"Darwin\"")
        _ = try makeRuntime("java-17", release: "JAVA_VERSION=\"17.0.9\"")
        _ = try makeRuntime("openjdk-21-whatever", release: nil)   // 폴더 이름 폴백

        let found = JavaInstallStore.installed(in: root)
        XCTAssertEqual(found.map(\.majorVersion), [8, 17, 21])

        // 최소 버전 이상 중 가장 낮은 것을 고른다 — 필요 이상으로 높은 JRE 를 쓰면
        // 구버전 마인크래프트가 모듈 캡슐화에 걸려 죽는다.
        XCTAssertEqual(JavaInstallStore.select(minVersion: 8, from: found)?.majorVersion, 8)
        XCTAssertEqual(JavaInstallStore.select(minVersion: 17, from: found)?.majorVersion, 17)
        // ⚠️ 예전에는 여기서 21 을 돌려줬다(가장 높은 것으로 폴백). 그게 MC 26.2 를
        //    Java 21 로 띄워 UnsupportedClassVersionError 로 죽게 만든 원인이다.
        //    못 맞추면 nil 이어야 호출자가 "Java 25 가 필요합니다"를 띄운다.
        XCTAssertNil(JavaInstallStore.select(minVersion: 25, from: found))
    }

    // MARK: - 헬퍼

    /// 최소 ZIP 라이터. 테스트에서만 쓴다(앱은 읽기만 한다).
    private func makeZip(entries: [(String, Data)]) throws -> Data {
        var local = Data()
        var central = Data()
        var offsets: [Int] = []

        for (name, payload) in entries {
            offsets.append(local.count)
            let compressed = deflate(payload)
            let nameBytes = Data(name.utf8)

            local.append(le32(0x0403_4b50)); local.append(le16(20)); local.append(le16(0))
            local.append(le16(8)); local.append(le16(0)); local.append(le16(0))
            local.append(le32(0))                                   // crc (리더가 안 본다)
            local.append(le32(UInt32(compressed.count)))
            local.append(le32(UInt32(payload.count)))
            local.append(le16(UInt16(nameBytes.count))); local.append(le16(0))
            local.append(nameBytes)
            local.append(compressed)
        }

        for (index, (name, payload)) in entries.enumerated() {
            let compressed = deflate(payload)
            let nameBytes = Data(name.utf8)
            central.append(le32(0x0201_4b50)); central.append(le16(20)); central.append(le16(20))
            central.append(le16(0)); central.append(le16(8)); central.append(le16(0))
            central.append(le16(0)); central.append(le32(0))
            central.append(le32(UInt32(compressed.count)))
            central.append(le32(UInt32(payload.count)))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le32(0))
            central.append(le32(UInt32(offsets[index])))
            central.append(nameBytes)
        }

        var out = local
        let centralOffset = out.count
        out.append(central)
        out.append(le32(0x0605_4b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(UInt32(centralOffset)))
        out.append(le16(0))
        return out
    }

    private func deflate(_ data: Data) -> Data {
        var out = Data(count: max(data.count * 2, 128))
        let produced: Int = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return out.prefix(produced)
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    // MARK: - HUD 크기 (해상도 배율과의 톱니 관계)

    /// 우리 공식이 마인크래프트 `Window.calculateScale` 의 루프와 같은 답을 내는지 본다.
    /// 이게 어긋나면 설정 화면의 "HUD %" 가 거짓말을 하고, 사용자는 인벤토리를 키우려다
    /// 오히려 줄이는 배율을 고르게 된다.
    func testGuiScaleMatchesMinecraftLoop() {
        /// 마인크래프트 1.21.1 원문 그대로.
        func minecraftScale(_ fbW: Int, _ fbH: Int, guiScale: Int) -> Int {
            var i = 1
            while i != guiScale && i < fbW && i < fbH
                    && fbW / (i + 1) >= 320 && fbH / (i + 1) >= 240 {
                i += 1
            }
            return i
        }

        // 아이폰 15 가로 실측(100% 프레임버퍼 2556x1118)
        let fullW = 2556, fullH = 1118
        for percent in stride(from: JvmSettings.resScaleMin, through: JvmSettings.resScaleMax, by: 5) {
            let w = fullW * percent / 100, h = fullH * percent / 100
            XCTAssertEqual(
                JvmSettings.guiScale(fullHeightPx: fullH, percent: percent),
                minecraftScale(w, h, guiScale: 4),
                "배율 \(percent)% (\(w)x\(h))"
            )
        }
    }

    /// 톱니가 실제로 톱니인지 — 배율을 올렸는데 HUD 가 작아지는 구간이 있어야 한다.
    /// (없다면 라벨을 붙일 이유도 없으므로 이 테스트가 기능의 존재 이유다)
    func testHudSizeIsNotMonotonicInResolution() {
        let fullH = 1118
        func hud(_ p: Int) -> Double { JvmSettings.hudRelativeSize(fullHeightPx: fullH, percent: p) }

        XCTAssertGreaterThan(hud(45), hud(55), "45% 가 55% 보다 HUD 가 커야 한다")
        XCTAssertGreaterThan(hud(65), hud(55))
        XCTAssertLessThan(hud(100), hud(65), "네이티브가 오히려 65% 보다 작다")
    }


    /// HUD 를 키우되 **화면 밖으로 밀어내지 않는다**는 보장. 이게 깨지면 인벤토리는
    /// 커졌는데 대형 상자를 못 쓰게 된다 — 사용자 입장에서는 그냥 고장이다.
    func testHudClampNeverClipsAndFloorGrantsExactly() {
        /// 마인크래프트 Window.calculateScale — 하한만 우리가 넘긴 값으로.
        func mcScale(_ w: Int, _ h: Int, guiScale: Int, floorW: Int, floorH: Int) -> Int {
            var i = 1
            while i != guiScale && i < w && i < h
                    && w / (i + 1) >= floorW && h / (i + 1) >= floorH { i += 1 }
            return i
        }

        let fullW = 2556, fullH = 1179      // 아이폰 15 가로 (SafeArea 없이)
        for percent in stride(from: JvmSettings.resScaleMin,
                              through: JvmSettings.resScaleMax, by: 5) {
            let w = fullW * percent / 100, h = fullH * percent / 100
            for want in 1...4 {
                let eff = JvmSettings.effectiveHudScale(want, framebufferHeight: h)

                XCTAssertTrue(h / eff >= JvmSettings.tallestGuiHeight || eff == 1,
                              "\(percent)% \(want)배: 가상 높이 \(h / eff) 로 잘린다")

                var floorW = 320, floorH = 240
                if let spec = JvmSettings.guiFloorSpec(hudScale: want, framebuffer: (w, h)) {
                    let parts = spec.split(separator: "x").compactMap { Int($0) }
                    (floorW, floorH) = (parts[0], parts[1])
                }
                XCTAssertEqual(mcScale(w, h, guiScale: eff, floorW: floorW, floorH: floorH),
                               eff, "\(percent)% \(want)배: 하한이 그 스케일을 못 내준다")
            }
        }
    }

    /// 잠긴 단계에 안내하는 해상도가 실제로 그 단계를 열어야 한다.
    /// (틀리면 사용자가 시키는 대로 해도 아무 일이 안 일어난다)
    func testAdvertisedResolutionActuallyUnlocksHudScale() {
        let fullH = 1179
        for scale in 2...4 {
            guard let need = JvmSettings.minResolutionPercent(forHudScale: scale,
                                                              fullHeightPx: fullH) else { continue }
            let h = fullH * need / 100
            XCTAssertGreaterThanOrEqual(JvmSettings.maxHudScale(framebufferHeight: h), scale,
                                        "\(scale)배: \(need)% 로 올려도 안 열린다")
        }
    }






    /// **옛 instance.json 이 계속 읽혀야 한다.**
    ///
    /// ⚠️ Swift 가 합성하는 `Decodable` 은 프로퍼티 기본값을 쓰지 않는다 — 비옵셔널
    ///    필드는 키가 없으면 `keyNotFound` 로 던진다. 그래서 `InstanceMeta` 에
    ///    비옵셔널 필드를 새로 추가하면 **이미 저장된 인스턴스가 전부 디코딩에 실패**하고,
    ///    `InstanceStore.reload()` 의 `compactMap` 이 조용히 걸러내 목록에서 사라진다.
    ///    실제로 `memoryPressureTier: Int = 0` 을 넣었다가 이렇게 깨뜨렸다.
    ///    새 필드는 옵셔널로 넣고 읽을 때 기본값을 씌운다.
    ///
    ///    아래 JSON 은 실제 기기에서 뽑은 것이다(1.21.4 바닐라).
    func testLegacyInstanceJsonStillDecodes() throws {
        let legacy = """
        {"assetIndexId":"17","extraJars":[],"gameArgs":[],"gameJvmArgs":[],
         "iconEmoji":"🌿","id":"vanilla_1.21.4_25d9d9a0","lastPlayedAt":779200000,
         "mainClass":"net.minecraft.client.main.Main","mcVersion":"1.21.4",
         "name":"1.21.4","type":"VANILLA"}
        """
        let meta = try JSONDecoder().decode(InstanceMeta.self, from: Data(legacy.utf8))
        XCTAssertEqual(meta.id, "vanilla_1.21.4_25d9d9a0")
        XCTAssertEqual(meta.mcVersion, "1.21.4")
        XCTAssertNil(meta.rendererId, "없는 선택값은 nil 로 읽혀야 한다")

        // 안드로이드가 쓴 파일에는 iOS 전용 필드가 아예 없다 — 그것도 읽혀야 한다.
        let android = """
        {"id":"x","name":"x","type":"VANILLA","mcVersion":"1.21.1","assetIndexId":"17",
         "extraJars":[],"gameArgs":[],"gameJvmArgs":[],"iconEmoji":"🌿",
         "mainClass":"net.minecraft.client.main.Main"}
        """
        XCTAssertNoThrow(try JSONDecoder().decode(InstanceMeta.self, from: Data(android.utf8)))
    }

}
