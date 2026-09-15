import Foundation

/// 바닐라 MC 다운로더 — 모든 파일을 instanceDir 하위에 저장한다.
/// 안드로이드 `MinecraftDownloader` 이식. 디렉터리 레이아웃도 그대로 맞췄다.
///
/// ```
/// instanceDir/
///   assets/indexes/   assets/objects/
///   libraries/
///   versions/<versionId>/
/// ```
struct MinecraftDownloader {
    let instanceDir: URL
    let versionEntry: VersionEntry
    let onProgress: @Sendable (DownloadProgress) -> Void

    /// 에셋은 파일이 수천 개라 순차로 받으면 몇 분씩 걸린다.
    /// 안드로이드는 순차였지만, 여기서는 8개씩 병렬로 받는다.
    private let assetConcurrency = 8

    func prepare() async throws -> MCPrepareResult {
        onProgress(DownloadProgress(phase: .fetchingManifest))
        guard let url = URL(string: versionEntry.url) else {
            throw HTTP.StatusError(code: -1, url: versionEntry.url)
        }
        // 원본 JSON 도 남긴다 — 실행할 때 `javaVersion.majorVersion` 을 다시 읽어야 한다.
        // (바닐라 런처와 같은 자리: versions/<id>/<id>.json)
        let manifestData = try await HTTP.data(url)
        let manifest = try JSONDecoder().decode(VersionManifest.self, from: manifestData)
        let manifestFile = instanceDir.appending(path: "versions/\(manifest.id)/\(manifest.id).json")
        Paths.ensureDir(manifestFile.deletingLastPathComponent())
        try? manifestData.write(to: manifestFile)

        // 1) 클라이언트 JAR
        onProgress(DownloadProgress(phase: .downloadingClient, fileName: "\(manifest.id).jar"))
        let clientJar = instanceDir.appending(path: "versions/\(manifest.id)/\(manifest.id).jar")
        try await HTTP.download(manifest.downloads.client.url, to: clientJar)

        // 2) 에셋 인덱스
        let assetIndexFile = instanceDir.appending(path: "assets/indexes/\(manifest.assetIndex.id).json")
        try await HTTP.download(manifest.assetIndex.url, to: assetIndexFile)

        // 3) 라이브러리
        let librariesDir = instanceDir.appending(path: "libraries")
        let artifacts = manifest.libraries.compactMap { lib -> (String, DownloadItem)? in
            guard let artifact = lib.downloads?.artifact else { return nil }
            return (Maven.path(lib.name), artifact)
        }
        for (index, (path, artifact)) in artifacts.enumerated() {
            let dest = librariesDir.appending(path: path)
            onProgress(DownloadProgress(
                phase: .downloadingLibraries,
                current: index + 1, total: artifacts.count,
                fileName: dest.lastPathComponent
            ))
            // 라이브러리 하나가 404 여도 게임은 대개 뜬다(플랫폼별 네이티브 등).
            // 안드로이드도 실패를 로그만 남기고 넘어간다 — 여기서 던지면 설치가 통째로 실패한다.
            _ = try? await HTTP.download(artifact.url, to: dest)
        }

        // 4) 에셋 오브젝트
        try await downloadAssets(indexFile: assetIndexFile,
                                 objectsDir: instanceDir.appending(path: "assets/objects"))

        return MCPrepareResult(
            assetIndexId: manifest.assetIndex.id,
            mainClass: manifest.mainClass,
            minecraftArguments: manifest.minecraftArguments
        )
    }

    private struct AssetIndexFile: Decodable {
        struct Object: Decodable { let hash: String }
        let objects: [String: Object]
    }

    private func downloadAssets(indexFile: URL, objectsDir: URL) async throws {
        guard let data = try? Data(contentsOf: indexFile),
              let index = try? JSONDecoder().decode(AssetIndexFile.self, from: data)
        else { return }

        let hashes = index.objects.values.map(\.hash)
        let total = hashes.count
        let done = Counter()

        await withTaskGroup(of: Void.self) { group in
            var iterator = hashes.makeIterator()
            var inFlight = 0

            func addNext() {
                guard let hash = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    let prefix = String(hash.prefix(2))
                    let dest = objectsDir.appending(path: "\(prefix)/\(hash)")
                    _ = try? await HTTP.download(
                        "https://resources.download.minecraft.net/\(prefix)/\(hash)", to: dest
                    )
                    let n = await done.increment()
                    // 파일마다 UI 를 때리면 스크롤이 끊긴다 — 32개마다 한 번만 보고.
                    if n % 32 == 0 || n == total {
                        onProgress(DownloadProgress(
                            phase: .downloadingAssets, current: n, total: total,
                            fileName: String(hash.prefix(12)) + "..."
                        ))
                    }
                }
            }

            for _ in 0..<assetConcurrency { addNext() }
            while await group.next() != nil {
                inFlight -= 1
                addNext()
            }
        }
    }
}

private actor Counter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
}

/// "group:artifact:version[:classifier]" → 메이븐 저장소 상대 경로.
enum Maven {
    /// `group:artifact:version[:classifier][@확장자]` → 저장소 경로.
    ///
    /// ⚠️ `@확장자` 를 빠뜨리면 안 된다. Forge 설치 프로필은 매핑을
    ///    `net.minecraft:client:1.21.1:mappings@tsrg` 처럼 적는데, 이걸 `.jar` 로 저장하면
    ///    텍스트 파일이 `...-mappings@tsrg.jar` 이라는 이름으로 남는다.
    ///    클래스패스는 libraries/ 아래 `.jar` 을 전부 모으므로 그게 딸려 들어가고,
    ///    Forge 부트스트랩이 zip 으로 열다 "zip END header not found" 로 죽는다.
    static func path(_ coordinate: String) -> String {
        var coordinate = coordinate
        var ext = "jar"
        if let at = coordinate.firstIndex(of: "@") {
            ext = String(coordinate[coordinate.index(after: at)...])
            coordinate = String(coordinate[..<at])
        }

        let parts = coordinate.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return coordinate }
        let group = parts[0].replacingOccurrences(of: ".", with: "/")
        let artifact = parts[1]
        let version = parts[2]
        let classifier = parts.count > 3 && !parts[3].isEmpty ? "-\(parts[3])" : ""
        return "\(group)/\(artifact)/\(version)/\(artifact)-\(version)\(classifier).\(ext)"
    }
}
