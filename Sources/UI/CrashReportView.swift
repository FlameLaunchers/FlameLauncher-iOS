import SwiftUI

/// 크래시 리포트 뷰어. 안드로이드 `CrashReportScreen` 이식.
///
/// 인스턴스의 `crash-reports/` 와 `logs/latest.log` 를 읽어, 원인 줄을 위로 뽑아 보여준다.
/// 로그 전문을 그대로 던지면 사용자가 뭘 봐야 할지 모른다 — 안드로이드가 CrashLogParser 로
/// 하던 "요약 먼저, 전문은 아래" 구성을 그대로 유지했다.
struct CrashReportView: View {
    let instanceId: String

    @State private var reports: [Report] = []
    @State private var expanded: Set<String> = []

    struct Report: Identifiable {
        let url: URL
        let text: String
        var id: String { url.lastPathComponent }
        var name: String { url.lastPathComponent }

        /// 로그에서 실제 원인이 될 만한 줄만 추린다.
        var summary: [String] {
            let interesting = ["Caused by:", "Exception", "Error", "at net.minecraft",
                               "FATAL", "Failed to", "Mixin apply"]
            return text
                .components(separatedBy: .newlines)
                .filter { line in interesting.contains { line.contains($0) } }
                .prefix(12)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    var body: some View {
        ZStack {
            FlameColor.bgDark.ignoresSafeArea()

            if reports.isEmpty {
                VStack(spacing: 8) {
                    Text("🎉").font(.system(size: 40))
                    Text("크래시 기록이 없어요")
                        .font(.system(size: 13)).foregroundStyle(FlameColor.textSub)
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(reports) { report in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(report.name)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(FlameColor.textMain)
                                    Spacer()
                                    ShareLink(item: report.text) {
                                        Text("공유").font(.system(size: 11))
                                            .foregroundStyle(FlameColor.primary)
                                    }
                                }

                                ForEach(Array(report.summary.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(line.contains("Caused by")
                                                         ? FlameColor.red : FlameColor.textSub)
                                        .lineLimit(2)
                                }

                                Button(expanded.contains(report.id) ? "전문 접기" : "전문 보기") {
                                    if expanded.contains(report.id) { expanded.remove(report.id) }
                                    else { expanded.insert(report.id) }
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(FlameColor.primary)

                                if expanded.contains(report.id) {
                                    ScrollView {
                                        Text(report.text)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(FlameColor.textSub)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(height: 260)
                                    .padding(8)
                                    .flameCard(fill: FlameColor.bgDark, radius: 8)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .flameCard(radius: 12)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .navigationTitle("크래시 리포트")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
        .onAppear(perform: load)
    }

    private func load() {
        let dir = Paths.instance(instanceId)
        let candidates = [dir.appending(path: "crash-reports"), dir.appending(path: "logs")]
        reports = candidates
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0,
                                                                     includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
            .filter { ["txt", "log"].contains($0.pathExtension) }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { Report(url: url, text: $0) }
            }
            .sorted { $0.name > $1.name }
    }
}
