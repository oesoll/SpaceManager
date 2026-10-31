import SwiftUI
import UniformTypeIdentifiers

/// 탭 막대. 탭은 사이드바가 아니라 터미널 아래에서 오간다 — tmux 상태줄이 있던 자리다(SEOL 10/31).
///
/// herdr의 탭 막대(client/shell/tabs.rs)를 sm의 말로 옮겼다: 한 줄의 칩, 이름 양옆 여백, 칩 사이 한 칸,
/// 끝에 `+`, 끌어서 순서 바꾸기, 넘치면 옆으로 민다. herdr는 활성 탭을 강조색으로 꽉 채우지만, sm은 분홍을
/// 포커스 테두리와 상태 표시에 쓰고 있어 같은 분홍을 넓게 깔면 둘이 다툰다. 그래서 활성 탭은 옅은 분홍 면과
/// 진한 글자로만 가른다. 탭을 바꾸면 그 면이 페이드로 옮겨 간다. herdr처럼 확대 중인 탭은 이름 뒤에 Z를 붙이고,
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
    }

    let items: [Item]
    let onSelect: (String) -> Void
    var onClose: ((String) -> Void)?
    var onRename: ((String, String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    let onNew: () -> Void

    @State private var dragging: String?
    @State private var dropIndex: Int?

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
                                    onRename: onRename.map { rename in { rename(item.id, $0) } })
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
            }
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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(item.isActive ? Color(Chrome.accent).opacity(0.16)
                                    : Color(isHovering ? Chrome.hover : .clear))
        }
        .animation(.easeInOut(duration: 0.25), value: item.isActive)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { rename() }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if onRename != nil { Button("이름 바꾸기…", action: rename) }
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
