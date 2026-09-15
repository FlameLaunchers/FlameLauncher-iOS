import Foundation

/// Mojang 버전 매니페스트. 안드로이드 `VersionRepository` 이식.
enum VersionService {
    static let manifestURL = URL.lit("https://piston-meta.mojang.com/mc/game/version_manifest.json")

    private static let cacheFile = Paths.caches.appending(path: "version_manifest.json")

    /// 버전 목록. 네트워크가 죽어 있으면 마지막으로 받아둔 캐시로 폴백한다
    /// (안드로이드에는 없던 동작 — 기내/지하철에서 앱이 빈 목록으로 뜨는 걸 막는다).
    ///
    /// ⚠️ 이 목록은 앱이 뜰 때 **한 번** 가져오고, 실패하면 그 세션 내내 빈 목록이었다.
    ///    콜드 스타트에서 한 번만 삐끗해도 "버전이 안 뜨고 모드팩 설치도 안 되는"
    ///    상태가 되는데 화면에는 아무 설명이 없었다(모드팩 설치는 이 목록에서 베이스
    ///    버전을 찾는다). 그래서 몇 번 다시 시도하고, 그래도 안 되면 **이유를 남긴다.**
    static func versions() async -> [VersionEntry] {
        for attempt in 0..<3 {
            do {
                let data = try await HTTP.data(manifestURL)
                let index = try JSONDecoder().decode(VersionManifestIndex.self, from: data)
                try? data.write(to: cacheFile, options: .atomic)
                lastError = nil
                return index.versions
            } catch {
                lastError = error
                // 0.5s → 1s. 콜드 스타트의 일시적 실패를 넘기는 정도면 충분하다.
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(500 << attempt))
                }
            }
        }

        if let cached = try? Data(contentsOf: cacheFile),
           let index = try? JSONDecoder().decode(VersionManifestIndex.self, from: cached) {
            return index.versions
        }
        return []
    }

    /// 마지막 실패 사유. 목록이 비었을 때 화면에 그대로 보여준다.
    private(set) static var lastError: Error?
}
