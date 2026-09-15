import SwiftUI

/// 가상 키패드 편집기. 안드로이드 `KeyboardLayoutEditorScreen` 이식.
///
/// 버튼을 끌어서 옮기고, 선택한 버튼은 크기를 조절하거나 지울 수 있다.
/// 좌표는 화면 비율(0~1)로 저장하므로 기기가 바뀌어도 배치가 유지된다.
///
/// ⚠️ 버튼 크기 공식(`KeyMetrics`)은 실제 게임 화면과 **공유해야** 한다.
///    두 화면의 크기 계산이 어긋나면 편집한 결과가 게임에서 다르게 보인다.
struct KeyLayoutEditorView: View {
    @State private var layout = KeyLayoutStore.load()
    @State private var selectedId: String?
    @State private var showAddSheet = false
    @State private var saved = false

    private var selected: KeyButton? { layout.first { $0.id == selectedId } }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 게임 화면을 흉내 낸 배경 — 버튼 위치를 실제와 같은 비율로 보게 한다.
                LinearGradient(colors: [FlameColor.bgDark, Color.black],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .onTapGesture { selectedId = nil }

                Text("버튼을 끌어서 배치하세요")
                    .font(.system(size: 11))
                    .foregroundStyle(FlameColor.textSub.opacity(0.6))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                ForEach(layout) { button in
                    DraggableKey(
                        button: button,
                        canvas: geo.size,
                        selected: selectedId == button.id,
                        onSelect: { selectedId = button.id },
                        onMove: { move(button.id, to: $0, in: geo.size) }
                    )
                }

                if let selected { inspector(selected).padding(12) }
            }
        }
        .navigationTitle("키 배치 편집")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("＋ 키") { showAddSheet = true }
                    .foregroundStyle(FlameColor.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("저장") {
                        KeyLayoutStore.save(layout)
                        flashSaved()
                    }
                    Button("기본값으로 되돌리기", role: .destructive) {
                        layout = KeyLayoutStore.reset()
                        selectedId = nil
                    }
                } label: {
                    Text("⋯").foregroundStyle(FlameColor.textMain)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddKeySheet { info in
                showAddSheet = false
                add(info)
            }
        }
        .overlay(alignment: .top) {
            if saved {
                Text("✅ 배치를 저장했어요")
                    .font(.system(size: 12))
                    .foregroundStyle(FlameColor.primary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .flameCard(radius: 10)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - 선택된 버튼 조작

    private func inspector(_ button: KeyButton) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(button.label) 편집")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(FlameColor.textMain)

            HStack(spacing: 8) {
                stepper("가로", value: button.width) { resize(button.id, dw: $0, dh: 0) }
                stepper("세로", value: button.height) { resize(button.id, dw: 0, dh: $0) }
            }

            HStack(spacing: 8) {
                Button(button.isAccent ? "강조 해제" : "강조") { toggleAccent(button.id) }
                    .font(.system(size: 12))
                    .foregroundStyle(FlameColor.primary)
                Spacer()
                Button("삭제", role: .destructive) {
                    layout.removeAll { $0.id == button.id }
                    selectedId = nil
                }
                .font(.system(size: 12))
                .foregroundStyle(FlameColor.red)
            }
        }
        .padding(12)
        .frame(width: 240)
        .flameCard(radius: 12)
    }

    private func stepper(_ title: String, value: Double,
                         onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(FlameColor.textSub)
            Button("−") { onChange(-8) }.buttonStyle(.bordered).tint(FlameColor.primary)
            Text("\(Int(value))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlameColor.textMain)
                .frame(width: 26)
            Button("＋") { onChange(8) }.buttonStyle(.bordered).tint(FlameColor.primary)
        }
    }

    // MARK: - 편집

    private func move(_ id: String, to point: CGPoint, in canvas: CGSize) {
        guard let index = layout.firstIndex(where: { $0.id == id }) else { return }
        layout[index].x = min(max(point.x / canvas.width, 0.03), 0.97)
        layout[index].y = min(max(point.y / canvas.height, 0.03), 0.97)
    }

    private func resize(_ id: String, dw: Double, dh: Double) {
        guard let index = layout.firstIndex(where: { $0.id == id }) else { return }
        // 접근성 최소 터치 타깃 아래로는 못 내려가게 막는다.
        layout[index].width = min(max(layout[index].width + dw, 36), 140)
        layout[index].height = min(max(layout[index].height + dh, 36), 140)
    }

    private func toggleAccent(_ id: String) {
        guard let index = layout.firstIndex(where: { $0.id == id }) else { return }
        layout[index].isAccent.toggle()
    }

    private func add(_ info: GlfwKeyCatalog.KeyInfo) {
        // 같은 키를 두 번 올리면 하나는 영원히 가려진다 — id 에 순번을 붙여 구분한다.
        let base = "k\(info.code)"
        var id = base
        var suffix = 1
        while layout.contains(where: { $0.id == id }) {
            suffix += 1
            id = "\(base)_\(suffix)"
        }
        layout.append(KeyButton(id: id, label: info.label, glfwCode: info.code, x: 0.5, y: 0.5))
        selectedId = id
    }

    private func flashSaved() {
        withAnimation { saved = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { saved = false }
        }
    }
}

private struct DraggableKey: View {
    let button: KeyButton
    let canvas: CGSize
    let selected: Bool
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        let rect = KeyMetrics.rect(for: button, in: canvas)

        Text(button.label)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(width: rect.width, height: rect.height)
            .background(
                button.isAccent
                    // ⚠️ 여기도 마젠타 RGB 가 박혀 있었다 — 인게임 버튼과 같은 색이어야
                    //    편집 화면에서 본 대로 게임에 나온다.
                    ? FlameColor.dark.opacity(0.85)
                    : FlameColor.bgSurface.opacity(0.85),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? FlameColor.primary : Color.white.opacity(0.25),
                            lineWidth: selected ? 3 : 2)
            )
            .position(x: rect.midX + dragOffset.width, y: rect.midY + dragOffset.height)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSelect()
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        onMove(CGPoint(x: rect.midX + value.translation.width,
                                       y: rect.midY + value.translation.height))
                        dragOffset = .zero
                    }
            )
    }
}

private struct AddKeySheet: View {
    let onAdd: (GlfwKeyCatalog.KeyInfo) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                FlameColor.bgDark.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(GlfwKeyCatalog.grouped, id: \.0) { group, keys in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(FlameColor.textSub)
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5),
                                          spacing: 8) {
                                    ForEach(keys) { key in
                                        Button { onAdd(key) } label: {
                                            Text(key.label)
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(FlameColor.textMain)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.6)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 12)
                                                .flameCard(fill: FlameColor.bgItem, radius: 8)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("키 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlameColor.bgSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }.foregroundStyle(FlameColor.textSub)
                }
            }
        }
    }
}
