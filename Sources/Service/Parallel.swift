import Foundation

/// 여러 다운로드를 동시에 돌리기 위한 최소 도구. Foundation 말고는 아무것도 안 쓴다
/// (의존이 없어야 `swiftc Sources/Service/Parallel.swift check.swift` 로 바로 검증할 수 있다).
enum Parallel {
    /// `items` 를 최대 `limit` 개씩 겹쳐서 처리한다. 하나가 끝나면 곧바로 다음 것을 채워 넣는다.
    ///
    /// 완료 순서는 보장하지 않는다 — 다운로드는 서로 독립이다.
    /// 보장하는 건 **모든 항목이 정확히 한 번씩** 처리되고, 동시 실행이 `limit` 을 넘지 않는 것.
    static func forEach<T: Sendable>(
        _ items: [T], limit: Int = 12, _ body: @escaping @Sendable (T) async -> Void
    ) async {
        guard !items.isEmpty, limit > 0 else { return }
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<min(limit, items.count) {
                if let item = iterator.next() { group.addTask { await body(item) } }
            }
            while await group.next() != nil {
                if let item = iterator.next() { group.addTask { await body(item) } }
            }
        }
    }
}

/// 병렬 작업의 진행 개수 세기용.
actor Counter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
}
