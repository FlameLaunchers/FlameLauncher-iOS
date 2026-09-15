import Foundation

/// 안드로이드의 `context.filesDir` / `getExternalFilesDir(null)` / `cacheDir` 대응.
///
/// - filesDir  → Application Support (백업 대상, 설정 JSON)
/// - external  → Documents (파일 앱에 노출됨 = 사용자가 모드/맵을 직접 넣을 수 있음)
/// - cacheDir  → Caches
enum Paths {
    static let files = url(for: .applicationSupportDirectory)
    static let external = url(for: .documentDirectory)
    static let caches = url(for: .cachesDirectory)

    static var instances: URL { external.appending(path: "instances") }
    static func instance(_ id: String) -> URL { instances.appending(path: id) }
    static var runtime: URL { files.appending(path: "runtime") }

    /// ⚠️ 반드시 **심볼릭 링크를 푼 실제 경로**로 돌려준다.
    ///
    /// iOS 가 주는 경로는 `/var/mobile/…` 인데 실제로는 `/private/var/mobile/…` 이다.
    /// 프로세스 CWD 는 커널이 풀어서 `/private/var/…` 로 잡히므로, 우리가 넘긴 경로만
    /// `/var/…` 로 남으면 **같은 폴더인데 문자열이 달라진다**.
    /// 경로를 문자열로 비교하는 코드가 한쪽만 /private 일 때 어긋난다.
    ///
    /// ⚠️ 참고: `Path.toRealPath()` 는 이걸로 해결되지 않는다. iOS 샌드박스는
    ///    최상위 `/private` 과 `/var` 의 stat 자체를 막아서, 어떤 형태로 넣어도
    ///    "Operation not permitted" 로 실패한다(실측). `Files.exists` 나 일반
    ///    파일 열기는 정상이므로 대부분의 코드는 영향받지 않는다.
    ///
    /// `URL.resolvingSymlinksInPath()` 는 쓰면 안 된다 — 애플 구현은 반대로
    /// `/private` 접두어를 **떼어낸다**. C 의 realpath 를 써야 한다.
    private static func url(for dir: FileManager.SearchPathDirectory) -> URL {
        let u = FileManager.default.urls(for: dir, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(u.path, &buffer) != nil else { return u }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// filesDir 안의 JSON 한 파일에 값 하나를 저장하는 얇은 헬퍼.
/// 안드로이드가 `SettingManager` / `JvmSettingsManager` / `KeyLayoutManager` 마다
/// 똑같은 read/write/try-catch 를 세 번 복붙해둔 걸 하나로 합쳤다.
struct JSONFile<T: Codable> {
    let name: String
    let fallback: T

    var url: URL { Paths.files.appending(path: name) }

    func load() -> T {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(T.self, from: data)
        else { return fallback }
        return value
    }

    func save(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
