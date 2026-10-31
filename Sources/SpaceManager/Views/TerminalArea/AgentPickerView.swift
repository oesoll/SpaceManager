import SwiftUI

/// 새 패널에 무엇을 열지 고른다. tmux에서는 패널을 만들면 빈 명령줄이 떴지만, sm에서는 패널이 곧
/// 에이전트다(SEOL 10/31). 그래서 상자는 새 패널 안에 뜬다 — 고른 에이전트가 바로 그 자리에서 열린다.
/// 확정하기 전에는 배치 데이터를 건드리지 않는다. Esc면 패널이 흔적 없이 사라진다.
///
/// 두 갈래다. 위는 새로 열기(엔진·모델·effort·이름), 아래는 이 워크스페이스에서 화면 없이 도는
/// 세션을 이 패널로 가져오기. 이름이 곧 세션이라, 끝난 세션을 고르면 그 대화가 되살아난다.
struct AgentPickerView: View {
    let workspace: String
    @ObservedObject var context: AgentPickerContext
    /// 이름 기본값을 만든다(엔진마다 다르다). 이미 있는 이름과 겹치지 않게 부르는 쪽이 번호를 붙인다.
    let suggestName: (AgentEngine) -> String
    let onOpen: (AgentLaunchSpec) -> Void
    let onBring: (AgentPickerSession) -> Void
    let onCancel: () -> Void

    @State private var engine: AgentEngine
    @State private var modelID: String
    @State private var effort: QuickEffort
    @State private var name: String
    @State private var nameEdited = false
    @FocusState private var nameFocused: Bool

    init(workspace: String, context: AgentPickerContext, initial: AgentPickerDefaults,
         suggestName: @escaping (AgentEngine) -> String,
         onOpen: @escaping (AgentLaunchSpec) -> Void,
         onBring: @escaping (AgentPickerSession) -> Void,
         onCancel: @escaping () -> Void) {
        self.workspace = workspace
        self.context = context
        self.suggestName = suggestName
        self.onOpen = onOpen
        self.onBring = onBring
        self.onCancel = onCancel
        _engine = State(initialValue: initial.engine)
        _modelID = State(initialValue: initial.modelID)
        _effort = State(initialValue: initial.effort)
        _name = State(initialValue: suggestName(initial.engine))
    }

    private var models: [AgentModelChoice] { engine == .claude ? context.claudeModels : context.codexModels }
    private var model: AgentModelChoice? { models.first { $0.id == modelID } ?? models.first }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("새 에이전트")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(Chrome.textPrimary))
                Text(workspace)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(Chrome.textTertiary))
            }

            HStack(spacing: 18) {
                ForEach(AgentEngine.allCases) { candidate in
                    EngineTab(title: candidate.title, isSelected: engine == candidate) { select(candidate) }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    FieldLabel("모델")
                    HStack(spacing: 14) {
                        PlainMenu(title: model?.name ?? "—") {
                            ForEach(models) { option in
                                Button(option.name) { modelID = option.id; constrainEffort() }
                            }
                        }
                        FieldLabel("effort")
                        PlainMenu(title: effort.displayName) {
                            ForEach(model?.efforts ?? QuickEffort.allCases) { level in
                                Button(level.displayName) { effort = level }
                            }
                        }
                    }
                }
                GridRow {
                    FieldLabel("이름")
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color(Chrome.textPrimary))
                            .focused($nameFocused)
                            .onChange(of: name) { _, value in nameEdited = value != suggestName(engine) }
                            .onSubmit(open)
                        Rectangle().fill(Color(nameFocused ? Chrome.textTertiary : Chrome.hairline)).frame(height: 1)
                    }
                    .frame(width: 220)
                }
            }

            if !context.backgroundSessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Rectangle().fill(Color(Chrome.hairline)).frame(height: 1).padding(.bottom, 10)
                    Text("뒤에서 도는 세션 가져오기")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(Chrome.textSecondary))
                        .padding(.bottom, 2)
                    ForEach(context.backgroundSessions) { session in
                        BackgroundSessionRow(session: session) { onBring(session) }
                    }
                }
            }

            HStack(spacing: 14) {
                if let error = context.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.reconnectAmber)
                        .lineLimit(2)
                } else if context.isLaunching {
                    Text("띄우는 중…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(Chrome.textTertiary))
                }
                Spacer()
                Button(action: onCancel) {
                    Text("취소").font(.system(size: 12)).foregroundStyle(Color(Chrome.textSecondary))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: open) {
                    Text("열기")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(Chrome.accent).opacity(trimmedName.isEmpty ? 0.4 : 1)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || context.isLaunching)
            }
        }
        .padding(22)
        .frame(maxWidth: 400, alignment: .leading)
        .onAppear { nameFocused = true }
    }

    private func select(_ candidate: AgentEngine) {
        guard candidate != engine else { return }
        engine = candidate
        let list = candidate == .claude ? context.claudeModels : context.codexModels
        modelID = list.first?.id ?? ""
        constrainEffort()
        if !nameEdited { name = suggestName(candidate) }
    }

    private func constrainEffort() {
        guard let model, !model.efforts.contains(effort) else { return }
        effort = model.defaultEffort ?? model.efforts.first ?? .high
    }

    private func open() {
        guard !trimmedName.isEmpty, !context.isLaunching, let model else { return }
        onOpen(AgentLaunchSpec(engine: engine, modelID: model.id, effort: effort, name: trimmedName))
    }
}

/// 상자 하나의 데이터. 목록은 뒤에서 읽어 오고, 띄우는 동안·실패를 상자 안에 보인다.
final class AgentPickerContext: ObservableObject {
    @Published var claudeModels: [AgentModelChoice]
    @Published var codexModels: [AgentModelChoice]
    @Published var backgroundSessions: [AgentPickerSession] = []
    @Published var isLaunching = false
    @Published var error: String?

    init(claudeModels: [AgentModelChoice], codexModels: [AgentModelChoice], backgroundSessions: [AgentPickerSession] = []) {
        self.claudeModels = claudeModels
        self.codexModels = codexModels
        self.backgroundSessions = backgroundSessions
    }
}

enum AgentEngine: String, CaseIterable, Identifiable, Codable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
}

struct AgentModelChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let efforts: [QuickEffort]
    var defaultEffort: QuickEffort?
}

struct AgentLaunchSpec: Equatable {
    let engine: AgentEngine
    let modelID: String
    let effort: QuickEffort
    let name: String
}

/// 이 워크스페이스에서 패널 없이 도는(또는 끝난) 세션.
struct AgentPickerSession: Identifiable, Equatable {
    /// 세션 층의 status 그대로: 도는 중, 일부러 끝냄, 기기가 꺼지는 등으로 죽음.
    enum Status: Equatable { case running, ended, dead }
    let name: String
    let engine: AgentEngine
    let status: Status
    var lastActive: Date?
    var attention: AgentAttention?
    var id: String { name }
}

/// 마지막으로 고른 엔진·모델·effort. 다음 상자가 이것으로 시작한다.
struct AgentPickerDefaults: Codable, Equatable {
    var engine: AgentEngine
    var modelID: String
    var effort: QuickEffort

    private static let key = "agentPicker.last"

    static func load(fallback: AgentPickerDefaults) -> AgentPickerDefaults {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(AgentPickerDefaults.self, from: data) else { return fallback }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - 조각

/// 엔진 탭. 고른 쪽은 글자가 진하고 밑줄이 분홍이다 — tmux 상태줄의 현재 창 표시(밑줄)와 같은 말이다.
/// 글자까지 분홍으로 칠하면 상자 안의 분홍(포커스 테두리·열기 버튼)이 넷이 되어 어디가 행동인지 흐려진다.
private struct EngineTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color(isSelected ? Chrome.textPrimary : Chrome.textSecondary))
                Rectangle()
                    .fill(Color(Chrome.accent))
                    .frame(height: 2)
                    .opacity(isSelected ? 1 : 0)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color(Chrome.textTertiary))
    }
}

/// 테두리 없는 메뉴. 값과 작은 화살표만.
private struct PlainMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(Chrome.textPrimary))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color(Chrome.textTertiary))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct BackgroundSessionRow: View {
    let session: AgentPickerSession
    let action: () -> Void
    @State private var isHovering = false

    private var statusText: String {
        switch session.status {
        case .running:
            return session.attention.map(AgentStateMark.spokenName) ?? "도는 중"
        case .ended, .dead:
            let when = session.lastActive.map { PaneBadge.age(since: $0) + " 전" } ?? ""
            return [session.status == .dead ? "멈춤" : "끝남", when, "되살리기"].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                AgentStateMark(attention: session.status == .running ? session.attention : nil)
                Text(session.name)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Color(session.status == .running ? Chrome.textPrimary : Chrome.textSecondary))
                    .lineLimit(1)
                Text(session.engine.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(Chrome.textTertiary))
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(Chrome.textTertiary))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(isHovering ? Chrome.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
