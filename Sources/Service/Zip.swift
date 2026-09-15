import Foundation
import Compression

/// 최소 ZIP 리더 (.jar / .mrpack / .zip 모드팩·리소스팩·맵 가져오기용).
///
/// Foundation 에는 zip **해제** API 가 없고(압축은 NSFileCoordinator 로 되지만 해제는 없다),
/// 필요한 건 "중앙 디렉터리 읽고 엔트리별로 raw DEFLATE 풀기" 뿐이다. Compression 프레임워크가
/// 이미 raw DEFLATE 를 제공하므로 외부 패키지를 붙이는 대신 그 위에 얇게 얹었다.
///
/// ponytail: zip64 미지원(4GB↑ 아카이브 / 엔트리 65535개 초과). 모드팩·리소스팩은 한참 아래라
///           문제되지 않는다. 넘는 아카이브를 만나면 zip64 EOCD 파싱을 추가할 것.
enum Zip {
    struct Entry {
        let path: String
        let compressedSize: Int
        let uncompressedSize: Int
        let method: UInt16      // 0 = stored, 8 = deflate
        let localHeaderOffset: Int
        var isDirectory: Bool { path.hasSuffix("/") }
    }

    enum ZipError: LocalizedError {
        case notAZip
        case unsupportedMethod(UInt16)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: return "ZIP 파일이 아닙니다 (중앙 디렉터리를 찾지 못함)"
            case .unsupportedMethod(let m): return "지원하지 않는 압축 방식: \(m)"
            case .corrupt(let m): return "손상된 ZIP: \(m)"
            }
        }
    }

    /// 아카이브의 엔트리 목록.
    static func entries(of data: Data) throws -> [Entry] {
        guard let eocd = findEOCD(data) else { throw ZipError.notAZip }
        let count = Int(data.u16(eocd + 10))
        var offset = Int(data.u32(eocd + 16))

        var out: [Entry] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(offset) == 0x0201_4b50 else {
                throw ZipError.corrupt("중앙 디렉터리 헤더 서명 불일치 @\(offset)")
            }
            let nameLen = Int(data.u16(offset + 28))
            let extraLen = Int(data.u16(offset + 30))
            let commentLen = Int(data.u16(offset + 32))
            let nameRange = (offset + 46)..<(offset + 46 + nameLen)
            let name = String(decoding: data[nameRange], as: UTF8.self)

            out.append(Entry(
                path: name,
                compressedSize: Int(data.u32(offset + 20)),
                uncompressedSize: Int(data.u32(offset + 24)),
                method: data.u16(offset + 10),
                localHeaderOffset: Int(data.u32(offset + 42))
            ))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    /// 엔트리 하나의 내용을 푼다.
    static func read(_ entry: Entry, from data: Data) throws -> Data {
        let lh = entry.localHeaderOffset
        guard lh + 30 <= data.count, data.u32(lh) == 0x0403_4b50 else {
            throw ZipError.corrupt("로컬 헤더 서명 불일치 @\(lh)")
        }
        // ⚠️ 파일명/extra 길이는 로컬 헤더 것을 써야 한다. 중앙 디렉터리와 extra 길이가
        //    다른 아카이브가 흔해서(정렬 패딩), 중앙 것을 쓰면 데이터 시작점이 어긋난다.
        let start = lh + 30 + Int(data.u16(lh + 26)) + Int(data.u16(lh + 28))
        let end = start + entry.compressedSize
        guard end <= data.count else { throw ZipError.corrupt("데이터 범위 초과: \(entry.path)") }
        let raw = data.subdata(in: start..<end)

        switch entry.method {
        case 0: return raw
        case 8: return try inflate(raw, expecting: entry.uncompressedSize)
        default: throw ZipError.unsupportedMethod(entry.method)
        }
    }

    /// 아카이브 전체를 [destination] 아래에 푼다.
    /// - Parameter strip: 앞에서 잘라낼 경로 접두사(mrpack 의 `overrides/` 같은 것).
    @discardableResult
    static func unzip(_ archive: URL, to destination: URL, strip: String? = nil) throws -> [URL] {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        return try unzip(data: data, to: destination, strip: strip)
    }

    @discardableResult
    static func unzip(data: Data, to destination: URL, strip: String? = nil) throws -> [URL] {
        var written: [URL] = []
        for entry in try entries(of: data) where !entry.isDirectory {
            var path = entry.path
            if let strip {
                guard path.hasPrefix(strip) else { continue }
                path = String(path.dropFirst(strip.count))
            }
            // zip-slip 방어: "../" 로 컨테이너 밖에 쓰는 아카이브를 막는다.
            guard !path.isEmpty, !path.contains("..") else { continue }

            let dest = destination.appending(path: path)
            Paths.ensureDir(dest.deletingLastPathComponent())
            try Zip.read(entry, from: data).write(to: dest, options: .atomic)
            written.append(dest)
        }
        return written
    }

    /// 아카이브 안의 한 파일만 꺼낸다(mrpack 의 modrinth.index.json 등).
    static func extract(_ path: String, from archive: URL) throws -> Data? {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard let entry = try entries(of: data).first(where: { $0.path == path }) else { return nil }
        return try read(entry, from: data)
    }

    // MARK: - 내부

    /// EOCD 는 파일 끝에 있지만 뒤에 최대 65535바이트 주석이 붙을 수 있어 뒤에서부터 찾는다.
    private static func findEOCD(_ data: Data) -> Int? {
        let minSize = 22
        guard data.count >= minSize else { return nil }
        let searchStart = max(0, data.count - minSize - 65_535)
        var i = data.count - minSize
        while i >= searchStart {
            if data.u32(i) == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func inflate(_ input: Data, expecting size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let produced: Int = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB     // Apple 의 COMPRESSION_ZLIB == raw DEFLATE
                )
            }
        }
        guard produced == size else {
            throw ZipError.corrupt("DEFLATE 결과 크기 불일치 (\(produced) != \(size))")
        }
        return output
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }
}
