import Foundation

/// 모드 개수로 정하는 성능 등급. 안드로이드 `PerfTier` 이식.
enum PerfTier {
    case vanilla, light, medium, heavy, extreme

    static func from(modCount: Int) -> PerfTier {
        switch modCount {
        case ..<1:    return .vanilla   // 바닐라/데이터팩 — 강제 하향 안 함
        case ..<30:   return .light
        case ..<80:   return .medium
        case ..<150:  return .heavy
        default:      return .extreme
        }
    }

    /// 등급별 강제 옵션값. 첫 실행에만 적용하고, 이후엔 사용자가 올린 값을 보존한다.
    ///
    ///  - renderDistance        : 청크 렌더 거리 (가장 무거운 항목)
    ///  - simulationDistance    : 시뮬레이션 거리 (엔티티/틱 부하) — 1.18+
    ///  - graphicsMode          : 0=Fast, 1=Fancy, 2=Fabulous
    ///  - entityDistanceScaling : 엔티티 렌더 비율
    ///  - particles             : 0=All, 1=Decreased, 2=Minimal
    ///  - ao                    : 앰비언트 오클루전
    ///  - biomeBlendRadius      : 바이옴 경계 블렌딩 반경
    var floorOptions: [String: String]? {
        switch self {
        case .vanilla: return nil
        case .light: return [
            "renderDistance": "8", "simulationDistance": "6", "graphicsMode": "1",
            "entityDistanceScaling": "0.75", "particles": "1", "biomeBlendRadius": "1",
        ]
        case .medium: return [
            "renderDistance": "6", "simulationDistance": "5", "graphicsMode": "0",
            "entityDistanceScaling": "0.75", "particles": "1", "ao": "1",
            "biomeBlendRadius": "1", "renderClouds": "false",
        ]
        case .heavy: return [
            "renderDistance": "5", "simulationDistance": "4", "graphicsMode": "0",
            "entityDistanceScaling": "0.5", "particles": "2", "ao": "0",
            "biomeBlendRadius": "0", "renderClouds": "false",
        ]
        case .extreme: return [
            "renderDistance": "4", "simulationDistance": "4", "graphicsMode": "0",
            "entityDistanceScaling": "0.5", "particles": "2", "ao": "0",
            "biomeBlendRadius": "0", "renderClouds": "false",
            "fancyGraphics": "false",   // 일부 레거시 버전은 graphicsMode 대신 이 키를 쓴다
        ]
        }
    }
}

/// `options.txt` 동기화. 안드로이드 `syncOptionsTxt` 이식.
///
///  1) 첫 실행에만: maxFps / vsync / 렌더 거리 / 언어 / 성능 등급별 하향
///  2) 매 실행 강제: mipmapLevels=0
///  3) 그 외(키 바인딩/볼륨 등)는 사용자 변경을 보존
enum GameOptions {

    /// options.txt 를 읽어 guiScale 을 돌려준다(핫바 터치 영역 계산에 쓴다).
    @discardableResult
    static func sync(
        file: URL, settings: JvmSettings, modCount: Int, versionId: String,
        hudScale: Int
    ) -> Int {
        var lines = (try? String(contentsOf: file, encoding: .utf8))?
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty } ?? []

        func upsert(_ key: String, _ value: String) {
            let line = "\(key):\(value)"
            if let i = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) {
                lines[i] = line
            } else {
                lines.append(line)
            }
        }
        func currentInt(_ key: String) -> Int? {
            lines.first { $0.hasPrefix("\(key):") }
                .flatMap { Int($0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)) }
        }

        // "최초 1회" 판정은 같은 폴더의 마커 파일 부재로 한다.
        // 마커가 있으면 사용자가 게임 안에서 바꾼 설정을 절대 덮어쓰지 않는다.
        let marker = file.deletingLastPathComponent().appending(path: ".flame_perf_applied")
        let isFirstLaunch = !FileManager.default.fileExists(atPath: marker.path)
        let tier = PerfTier.from(modCount: modCount)

        if isFirstLaunch {
            upsert("maxFps", settings.unlockFps ? "260" : "120")
            upsert("enableVsync", settings.unlockFps ? "false" : "true")
            upsert("renderDistance", String(modCount > 0 ? 2 : settings.renderDistance))
            upsert("graphicsMode", String(settings.graphicsMode))
            upsert("renderClouds", settings.disableClouds ? "false" : "true")
            if supportsSimulationDistance(versionId) {
                upsert("simulationDistance", "5")
            }

            // 최초 실행 시 시스템 언어를 마인크래프트 언어로 설정.
            // ⚠️ pre-1.6 은 StringTranslate NPE 때문에 lang 을 건드리지 않는다(있으면 지운다).
            if isPre16(versionId) {
                lines.removeAll { $0.hasPrefix("lang:") }
            } else if !lines.contains(where: { $0.hasPrefix("lang:") }) {
                upsert("lang", minecraftLang())
            }

            // 첫 실행 + 무거운 모드팩 → 렌더 설정 강제 하향.
            // 정수형 옵션은 "기존 값이 더 낮으면 그 값 유지"(절대 높이지 않음).
            for (key, value) in tier.floorOptions ?? [:] {
                if let floor = Int(value), let current = currentInt(key) {
                    upsert(key, String(min(current, floor)))
                } else {
                    upsert(key, value)
                }
            }

            try? "tier=\(tier) modCount=\(modCount)\n".write(to: marker, atomically: true, encoding: .utf8)
        }

        // ── mipmapLevels 만 예외: 매 실행 강제 0 ──
        //   밉맵이 1 이상이면 텍스처 아틀라스가 밉맵 포함 형태로 생성되는데, 일부 모바일
        //   GL 드라이버 + Zink(OSMesa) 조합에서 힙이 손상돼 렌더 스레드가 강제 종료된다.
        //   크래시 방지는 타협 불가라 사용자 설정 보존 대상에서 제외한다.
        if currentInt("mipmapLevels") != 0 { upsert("mipmapLevels", "0") }

        // ── HUD 크기: 사용자가 정했으면 매 실행 강제 ──
        //   "자동"(0)은 손대지 않는다 — 게임 안에서 바꾼 값을 그대로 둔다.
        //   0 이 아니면 에이전트가 하한을 낮춰 두므로 이 값이 실제로 먹는다.
        if hudScale > 0, currentInt("guiScale") != hudScale {
            upsert("guiScale", String(hudScale))
        }

        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return currentInt("guiScale") ?? 0
    }

    /// Iris 셰이더 그림자 렌더 거리 최소화. options.txt 와 같이 최초 1회만 적용.
    /// 1.12.x Forge 의 로딩 스플래시(SplashProgress)를 끈다.
    ///
    /// SplashProgress 는 **별도 스레드에서 GL 컨텍스트를 가져간다.** 그동안 클라이언트
    /// 스레드에는 현재 컨텍스트가 없어서, preInit 에서 GL 을 만지는 모드가 그대로 터진다
    /// (실측: Better Questing → Framebuffer.enableStencil →
    ///  "glCheckFramebufferStatus returned unknown status:0" — ANGLE 은 컨텍스트가 없으면 0 을 준다).
    /// 데스크톱은 컨텍스트 공유로 넘어가지만 모바일 GL 스택은 컨텍스트 하나뿐이다.
    /// 안드로이드는 예전부터 이걸 끈다(MinecraftActivity). 1.13+ 에는 이 구조가 없다.
    static func disableForgeSplash(instanceDir: URL, mcVersion: String) {
        guard mcVersion.range(of: #"\b1\.12(\.\d+)?\b"#, options: .regularExpression) != nil else { return }
        let file = instanceDir.appending(path: "config/splash.properties")

        // 이미 있으면 enabled 만 고치고 나머지 키는 그대로 둔다(Forge 가 만들어 둔 값 보존).
        var lines = (try? String(contentsOf: file, encoding: .utf8))?
            .components(separatedBy: .newlines) ?? []
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "enabled=false" }) { return }
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("enabled=") }
        lines.append("enabled=false")

        Paths.ensureDir(file.deletingLastPathComponent())
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func syncIris(file: URL) {
        let marker = file.deletingLastPathComponent().appending(path: ".flame_iris_applied")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        var lines = (try? String(contentsOf: file, encoding: .utf8))?
            .components(separatedBy: .newlines) ?? []
        lines.removeAll { $0.hasPrefix("maxShadowRenderDistance=") }
        lines.append("maxShadowRenderDistance=1")

        Paths.ensureDir(file.deletingLastPathComponent())
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try? "applied\n".write(to: marker, atomically: true, encoding: .utf8)
    }

    /// 시스템 언어 → 마인크래프트 lang 코드("ll_cc", 소문자). 실패 시 en_us.
    static func minecraftLang() -> String {
        guard let locale = Locale.preferredLanguages.first.map(Locale.init) else { return "en_us" }
        let language = locale.language.languageCode?.identifier.lowercased() ?? "en"
        if let region = locale.region?.identifier.lowercased() {
            return "\(language)_\(region)"
        }
        // 국가 코드가 없는 주요 언어는 마인크래프트가 실제로 제공하는 대표 변형으로.
        let defaults = ["ko": "ko_kr", "ja": "ja_jp", "zh": "zh_cn", "en": "en_us",
                        "de": "de_de", "fr": "fr_fr", "es": "es_es", "ru": "ru_ru",
                        "pt": "pt_br", "it": "it_it"]
        return defaults[language] ?? "en_us"
    }

    private static func supportsSimulationDistance(_ versionId: String) -> Bool {
        !VersionRules.isPre117(versionId)
    }

    private static func isPre16(_ versionId: String) -> Bool {
        let id = versionId.lowercased()
        if ["b1.", "a1.", "a0.", "c0.", "inf-", "rd-"].contains(where: id.hasPrefix) { return true }
        guard id.hasPrefix("1.") else { return false }
        return (Int(id.dropFirst(2).prefix { $0.isNumber }) ?? 99) < 6
    }
}
