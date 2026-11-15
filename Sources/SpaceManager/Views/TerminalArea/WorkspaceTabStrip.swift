import SwiftUI
import UniformTypeIdentifiers

/// 탭 막대. 탭은 사이드바가 아니라 터미널 아래에서 오간다(SEOL 10/31). 11/15부터 아래 한 줄을 다 쓰지 않고
/// 칩이 놓인 자리만 터미널 카드에서 파낸 노치 안에 선다(`BottomNotch`).
///
/// herdr의 탭 막대(client/shell/tabs.rs)를 sm의 말로 옮겼다: 한 줄의 칩, 이름 양옆 여백, 칩 사이 한 칸,
/// 끝에 `+`, 끌어서 순서 바꾸기, 넘치면 옆으로 민다. herdr는 활성 탭을 강조색으로 꽉 채우지만, sm은 분홍을
/// 포커스 테두리와 상태 표시에 쓰고 있어 같은 분홍을 넓게 깔면 둘이 다툰다. 그래서 활성 탭은 옅은 분홍 면과
/// 진한 글자로만 가른다. 탭을 바꾸면 그 면이 페이드로 옮겨 간다(렌더 서버에서, `FadingFill`). herdr처럼 확대 중인 탭은 이름 뒤에 Z를 붙이고,
/// sm은 사이드바에서 탭을 뺐으므로 그 안에서 가장 급한 상태를 칩 왼쪽에 작게 단다.
struct WorkspaceTabStrip: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let isActive: Bool
        var attention: AgentAttention?
        var isZoomed = false
        var isPending = false
        var canClose = true
        /// 이 탭 패널들의 노치 알림 id. 패널이 하나뿐인 탭은 이름표(와 그 ×)가 없어서 칩 메뉴로 지운다.
        var notices: [String] = []
        /// 패널이 하나뿐인 탭을 Fine으로 옮길 수 있는가(이름표 메뉴가 없는 탭).
        var canMoveToFine = false
    }

    let items: [Item]
    let onSelect: (String) -> Void
    var onClose: ((String) -> Void)?
    var onRename: ((String, String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    var onMoveToFine: ((String) -> Void)?
    let onNew: () -> Void
    /// 칩이 이보다 길면 옆으로 민다. 노치는 칩만큼만 넓어진다(`BottomNotch`).
    var maxWidth: CGFloat = .infinity

    @State private var dragging: String?
    @State private var contentWidth: CGFloat = 0
    @State private var dropIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 24

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 0) {
                            if dropIndex == index && dragging != nil && dragging != item.id {
                                DropMarker()
                            }
                            TabChip(item: item,
                                    onSelect: { onSelect(item.id) },
                                    onClose: item.canClose ? onClose.map { close in { close(item.id) } } : nil,
                                    onRename: onRename.map { rename in { rename(item.id, $0) } },
                                    onMoveToFine: item.canMoveToFine ? onMoveToFine.map { move in { move(item.id) } } : nil)
                                .id(item.id)
                                .onDrag {
                                    dragging = item.id
                                    return NSItemProvider(object: item.id as NSString)
                                }
                                .onDrop(of: [UTType.text], delegate: ChipDrop(index: index, dragging: $dragging,
                                                                               dropIndex: $dropIndex) { from in
                                    onMove?(from, index)
                                })
                        }
                    }
                    NewTabChip(action: onNew)
                }
                .padding(.horizontal, 2)
                // 탭이 생기고 닫히고 자리를 바꾸면 이웃 칩이 미끄러져 자리를 내준다(튀지 않는 스프링).
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0), value: items.map(\.id))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if reduceMotion { contentWidth = width } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) { contentWidth = width }
                    }
                }
            }
            .frame(width: contentWidth > 0 ? min(contentWidth, maxWidth) : nil)
            .onChange(of: items.first(where: \.isActive)?.id) { _, active in
                // herdr처럼 활성 탭이 보이게 민다.
                if let active { withAnimation(.easeInOut(duration: 0.2)) { scroller.scrollTo(active, anchor: .center) } }
            }
        }
        .frame(height: Self.height)
    }
}

private struct TabChip: View {
    let item: WorkspaceTabStrip.Item
    let onSelect: () -> Void
    let onClose: (() -> Void)?
    let onRename: ((String) -> Void)?
    var onMoveToFine: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let attention = item.attention, attention >= .working {
                AgentStateMark(attention: attention)
            }
            Text(item.isZoomed ? item.name + " Z" : item.name)
                .font(.system(size: 11.5, weight: item.isActive ? .semibold : .regular))
                .foregroundStyle(Color(item.isActive ? Chrome.textPrimary : Chrome.textSecondary))
                .italic(item.isPending)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: WorkspaceTabStrip.height - 2)
        .background {
            // 활성 면은 렌더 서버에서 페이드한다 — 탭을 바꾸는 순간은 메인 스레드가 새 배치를 그리느라
            // 바빠서, SwiftUI 페이드는 몇 장면으로 끊겼다(SEOL 10/31). 호버 면은 페이드 없이 바로 바뀐다.
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(isHovering && !item.isActive ? Chrome.hover : .clear))
                FadingFill(isOn: item.isActive, color: Chrome.accent.withAlphaComponent(0.16))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // 한 번 누르면 바로 고른다. 두 번 누르기와 한 번 누르기를 같은 자리에 차례로 걸면 SwiftUI는 한 번
        // 누른 것을 두 번째 클릭이 오는지 더블클릭 간격만큼 기다렸다가 처리해, 탭을 누를 때마다 늦었다
        // (SEOL 10/31 "완전히 로드된 이후에도 딜레이"). 두 번 누르기는 나란히(simultaneous) 받는다 — 첫
        // 클릭에 그 탭이 골라진 뒤 이름 바꾸기가 뜬다.
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture(count: 2).onEnded { rename() })
        .contextMenu {
            if !item.notices.isEmpty {
                Button("알림 지우기") { MainActor.assumeIsolated { item.notices.forEach(NotchOwner.shared.dismiss) } }
                Divider()
            }
            if onRename != nil { Button("이름 바꾸기…", action: rename) }
            if let onMoveToFine { Button("Fine으로 옮기기", action: onMoveToFine) }
            if let onClose {
                Divider()
                Button("탭 닫기", action: onClose)
            }
        }
        .help(onClose != nil ? "\(item.name) · 닫아도 세션은 뒤에서 계속 돈다" : item.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.isActive ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
    }

    private func rename() {
        guard let onRename else { return }
        let alert = NSAlert()
        alert.messageText = "탭 이름"
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        input.stringValue = item.name
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != item.name { onRename(name) }
    }
}

private struct NewTabChip: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(isHovering ? Chrome.textPrimary : Chrome.textTertiary))
                .frame(width: 24, height: WorkspaceTabStrip.height - 2)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(isHovering ? Chrome.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("새 탭 (⌘T)")
        .accessibilityLabel("새 탭")
    }
}

/// 끌어 놓을 자리. herdr와 같이 강조색 세로선 하나.
private struct DropMarker: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(Chrome.accent))
            .frame(width: 2, height: WorkspaceTabStrip.height - 6)
            .padding(.trailing, 2)
    }
}

private struct ChipDrop: DropDelegate {
    let index: Int
    @Binding var dragging: String?
    @Binding var dropIndex: Int?
    let move: (String) -> Void

    func dropEntered(info: DropInfo) { dropIndex = index }
    func dropExited(info: DropInfo) { if dropIndex == index { dropIndex = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; dropIndex = nil }
        guard let from = dragging else { return false }
        move(from)
        return true
    }
}
