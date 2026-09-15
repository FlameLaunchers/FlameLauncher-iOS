import SwiftUI

/// 모드 로더 선택 시트. 안드로이드 `LoaderSelectDialog` 이식.
///
/// 로더를 고르면 그 로더의 빌드 목록을 가져와 두 번째 단계로 넘어간다.
/// (안드로이드는 로더마다 별도 다이얼로그 분기였지만, 목록을 가져오는 함수만 다르고
///  UI 는 같아서 `LoaderAPI.builds(for:)` 하나로 합쳤다.)
struct LoaderSelectSheet: View {
    let version: VersionEntry
    let onLaunch: (ModLoader, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loader: ModLoader?
    @State private var builds: [LoaderBuild] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                FlameColor.bgDark.ignoresSafeArea()
                if let loader { buildList(loader) } else { loaderList }
            }
            .navigationTitle(loader == nil ? "MC \(version.id)" : loader!.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loader == nil ? "닫기" : "뒤로") {
                        if loader == nil { dismiss() } else { loader = nil; builds = [] }
                    }
                    .foregroundStyle(FlameColor.textSub)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var loaderList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(ModLoader.allCases) { item in
                    Button {
                        if item == .vanilla {
                            onLaunch(.vanilla, nil)
                        } else {
                            loader = item
                            Task { await loadBuilds(item) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(item.emoji).font(.system(size: 26))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.displayName)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(FlameColor.textMain)
                                Text(item.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(FlameColor.textSub)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Text("›").foregroundStyle(FlameColor.textSub)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .flameCard(radius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func buildList(_ loader: ModLoader) -> some View {
        if isLoading {
            ProgressView().tint(FlameColor.primary)
        } else if builds.isEmpty {
            VStack(spacing: 8) {
                Text("😕").font(.system(size: 40))
                Text("MC \(version.id) 용 \(loader.displayName) 빌드가 없어요")
                    .font(.system(size: 13)).foregroundStyle(FlameColor.textSub)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(builds) { build in
                        Button { onLaunch(loader, build.version) } label: {
                            HStack {
                                Text(build.version)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(FlameColor.textMain)
                                if build.recommended {
                                    Text("추천")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(FlameColor.primary)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(FlameColor.primary.opacity(0.15), in: Capsule())
                                } else if !build.stable {
                                    Text("beta")
                                        .font(.system(size: 10))
                                        .foregroundStyle(FlameColor.tagSnapshot)
                                }
                                Spacer()
                                Text("▶").font(.system(size: 12)).foregroundStyle(FlameColor.primary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .flameCard(radius: 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }

    private func loadBuilds(_ loader: ModLoader) async {
        isLoading = true
        builds = await LoaderAPI.builds(for: loader, mcVersion: version.id)
        isLoading = false
    }
}
