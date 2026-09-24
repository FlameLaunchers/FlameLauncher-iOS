import SwiftUI

/// 모드/모드팩/리소스팩/셰이더/맵 탐색. 안드로이드 `ContentPackBrowserScreen` 이식.
///
/// 상단: 소스(CurseForge/Modrinth) 세그먼트 + 종류 탭 + 검색창
/// 목록: 로고 · 이름 · 요약 · 다운로드 수
struct ContentBrowserView: View {
    @Environment(LauncherModel.self) private var launcher

    // 키가 있으면 CurseForge 를 기본으로 연다 — 모드팩이 훨씬 많다.
    @State private var source: ContentSource = CurseForgeAPI.isConfigured ? .curseforge : .modrinth
    @State private var type: ContentType = .modpack
    @State private var query = ""
    @State private var items: [ContentItem] = []
    @State private var isLoading = false
    @State private var showCaution = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            FlameColor.bgDark.ignoresSafeArea()

            VStack(spacing: 0) {
                filters
                list
            }
        }
        .navigationTitle(String(localized: "추가 콘텐츠"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
        .task { await search() }
        .onChange(of: source) { _, new in
            // 소스를 바꿨는데 그 소스에 없는 탭이면(Modrinth 의 맵) 되돌린다.
            if !ContentType.tabs(for: new).contains(type) { type = .modpack }
            scheduleSearch()
        }
        .onChange(of: type) { _, _ in
            // 모드팩은 호환성 경고를 한 번 띄운다(안드로이드와 동일).
            if type == .modpack, !AppSettingsStore.load().neverShowCautionAgain {
                showCaution = true
            }
            scheduleSearch()
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .alert("⚠️ 주의", isPresented: $showCaution) {
            Button("이해했습니다") {}
            Button("다시 보지 않기") {
                var s = AppSettingsStore.load()
                s.neverShowCautionAgain = true
                AppSettingsStore.save(s)
            }
        } message: {
            Text("모드팩은 기기·렌더러 조합에 따라 제대로 동작하지 않을 수 있습니다.")
        }
    }

    private var filters: some View {
        VStack(spacing: 8) {
            Picker("소스", selection: $source) {
                ForEach(ContentSource.allCases) { s in
                    Label {
                        Text(s.label + (s == .curseforge && !CurseForgeAPI.isConfigured ? " (키 없음)" : ""))
                    } icon: {
                        Image(s == .curseforge ? "curseforge" : "modrinth")
                            .resizable().scaledToFit()
                    }
                    .tag(s)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ContentType.tabs(for: source)) { t in
                        let selected = type == t
                        Button { type = t } label: {
                            Text("\(t.emoji) \(t.label)")
                                .font(.system(size: 12, weight: selected ? .bold : .regular))
                                .foregroundStyle(selected ? .white : FlameColor.textSub)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .flameSelectableCard(selected: selected, radius: 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("🔎").font(.system(size: 14))
                TextField(String(localized: "검색"), text: $query)
                    .font(.system(size: 13))
                    .foregroundStyle(FlameColor.textMain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button { query = "" } label: { Text("✕").foregroundStyle(FlameColor.textSub) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .flameCard(fill: FlameColor.bgItem, radius: 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(FlameColor.bgSurface)
    }

    @ViewBuilder
    private var list: some View {
        if isLoading && items.isEmpty {
            Spacer(); ProgressView().tint(FlameColor.primary); Spacer()
        } else if items.isEmpty {
            Spacer()
            VStack(spacing: 6) {
                Text(source == .curseforge && !CurseForgeAPI.isConfigured ? "🔑" : "🫥")
                    .font(.system(size: 40))
                Text(source == .curseforge && !CurseForgeAPI.isConfigured
                     ? String(localized: "CurseForge API 키가 없습니다. Info.plist 의 CURSEFORGE_API_KEY 를 채워주세요.")
                     : String(localized: "검색 결과가 없어요"))
                    .font(.system(size: 13)).foregroundStyle(FlameColor.textSub)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        Button { launcher.path.append(.contentDetail(item)) } label: {
                            ContentRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
        }
    }

    private func scheduleSearch() {
        // 타이핑마다 때리지 않도록 300ms 디바운스.
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func search() async {
        isLoading = true
        items = await ContentAPI.search(source: source, query: query, type: type,
                                        gameVersion: nil, loader: nil)
        isLoading = false
    }
}

struct ContentRow: View {
    let item: ContentItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.logoURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image("anvil").resizable().scaledToFit().padding(8)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FlameColor.textMain)
                    .lineLimit(1)
                Text(item.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(FlameColor.textSub)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text("⬇ \(item.downloadsLabel)")
                    if let author = item.author { Text("· \(author)").lineLimit(1) }
                }
                .font(.system(size: 10))
                .foregroundStyle(FlameColor.textSub.opacity(0.8))
            }

            Spacer()
            Text("›").foregroundStyle(FlameColor.textSub)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flameCard(radius: 12)
    }
}
