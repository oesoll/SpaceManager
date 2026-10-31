import SwiftUI

/// Right pane containing the selected terminal.
/// 탭 전환 UI는 사이드바의 워크스페이스 폴더링(WorkspaceTabRow)이 담당한다.
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.windowKind == .workspace && !TmuxBootstrap.isTmuxAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("tmux가 설치되어 있지 않아 셸 탭만 사용할 수 있습니다 — `brew install tmux` 후 재실행")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
            // 카드 바탕·테두리는 TabSurfaceView가 그린다 — 탭을 나누면 카드가 여럿이 된다.
            TabSurfaceView()
            if appState.windowKind == .workspace {
                // 탭은 tmux 상태줄이 있던 자리(아래 왼쪽)에서 오간다.
                TabStripBar(layouts: .shared, peers: .shared, interaction: appState.layoutInteraction)
                    .padding(.top, 6)
            }
        }
    }
}

/// Single terminal view for the selected session
struct SingleTerminalView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let session = appState.selectedSession {
            SessionContentView(session: session)
        } else if appState.windowKind == .quick {
            QuickHomeView()
        } else {
            VStack(spacing: 10) {
                Text("열린 터미널이 없습니다")
                    .font(.system(size: 13))
                    .foregroundColor(Color(Chrome.textTertiary))
                Button("새 터미널") {
                    appState.addDefaultTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 활성 대화가 없을 때 보이는 Hermes 홈. 프롬프트는 AppState를 거쳐 PTY 환경변수로
/// 전달되며 셸 명령 문자열에는 절대 보간되지 않는다.
struct QuickHomeView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var modelCatalog = QuickModelCatalog()
    @State private var prompt = ""
    @State private var selectedModelID: String
    @State private var selectedEffort: QuickEffort
    @State private var proxyEnabled: Bool
    @FocusState private var isPromptFocused: Bool

    init() {
        let saved = QuickComposerPreferences.load()
        _selectedModelID = State(initialValue: saved.modelID)
        _selectedEffort = State(initialValue: saved.effort)
        _proxyEnabled = State(initialValue: saved.proxyEnabled)
    }

    var body: some View {
        VStack(spacing: 28) {
            // 장식 아이콘 없이 글자 위계만으로 선다 — Fine 홈과 같은 서체·자간.
            VStack(spacing: 10) {
                Text("새 대화 시작")
                    .font(HomeFont.greeting(31))
                    .tracking(-1.0)
                    .foregroundColor(.primary)
                Text("무엇을 도와드릴까요?")
                    .font(HomeFont.note)
                    .tracking(0.1)
                    .foregroundColor(.secondary.opacity(0.85))
            }

            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("무엇이든 물어보세요")
                            .font(HomeFont.prompt)
                            .foregroundColor(Color.secondary.opacity(0.6))
                            .padding(.top, 2)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(HomeFont.prompt)
                        .lineSpacing(4)
                        .lineLimit(3...10)
                        .focused($isPromptFocused)
                        .onSubmit(submit)
                        .padding(.horizontal, 4)
                }
                .frame(minHeight: 56, alignment: .topLeading)

                HStack(spacing: 10) {
                    modelPicker
                    effortPicker
                    proxyButton

                    Spacer()

                    // Fine의 보내기 버튼: 둥근 사각형, 쓸 수 있을 때만 짙은 솔잎색.
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(trimmedPrompt.isEmpty ? Color.secondary : Color.white)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(trimmedPrompt.isEmpty
                                          ? Color.black.opacity(0.05)
                                          : Color(red: 0.22, green: 0.27, blue: 0.23))
                            )
                            .animation(.spring(response: 0.25, dampingFraction: 1), value: trimmedPrompt.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedPrompt.isEmpty)
                }

                Text(sessionModeDescription)
                    .font(HomeFont.caption)
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(20)
            // 테두리는 머리카락 한 올, 그림자는 바탕색 쪽으로 기운 아주 옅은 한 겹 —
            // 회색 테두리와 짙은 이중 그림자는 카드를 무겁게 들어 올렸다.
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: Color(red: 0.27, green: 0.30, blue: 0.26).opacity(0.08), radius: 24, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
            )
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .onAppear {
            isPromptFocused = true
            modelCatalog.refresh()
        }
        .onChange(of: selectedModelID) { _, modelID in
            if modelID.hasPrefix("claude-codex-") {
                proxyEnabled = true
            }
            constrainSelectedEffort()
            persistSelection()
        }
        .onChange(of: selectedEffort) {
            persistSelection()
        }
        .onChange(of: proxyEnabled) {
            persistSelection()
        }
        .onChange(of: modelCatalog.models) { _, models in
            let resolved = QuickComposerPreferences.resolved(
                currentConfiguration,
                availableModels: models
            )
            selectedModelID = resolved.modelID
            selectedEffort = resolved.effort
            proxyEnabled = resolved.proxyEnabled
            QuickComposerPreferences.save(resolved)
        }
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let initialPrompt = trimmedPrompt
        guard !initialPrompt.isEmpty else { return }
        prompt = ""
        appState.addQuickSession(
            initialPrompt: initialPrompt,
            configuration: QuickSessionConfiguration(
                modelID: selectedModelID,
                effort: selectedEffort,
                proxyEnabled: proxyEnabled
            )
        )
    }

    private var selectedModel: QuickModelOption {
        modelCatalog.models.first(where: { $0.id == selectedModelID })
            ?? QuickModelCatalog.fallbackModels[1]
    }

    private var modelPicker: some View {
        Menu {
            Section("Claude") {
                ForEach(modelCatalog.models.filter { !$0.isCodex }) { model in
                    modelButton(model)
                }
            }
            let codexModels = modelCatalog.models.filter(\.isCodex)
            if !codexModels.isEmpty {
                Section("Codex · 프록시") {
                    ForEach(codexModels) { model in
                        modelButton(model)
                    }
                }
            }
        } label: {
            pickerLabel(selectedModel.displayName, icon: "sparkle")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(modelCatalog.routerAvailable ? "대화 모델 선택" : "라우터 오프라인 — Claude 모델만 사용 가능")
    }

    private var effortPicker: some View {
        Menu {
            ForEach(selectedModel.supportedEfforts) { effort in
                Button {
                    selectedEffort = effort
                } label: {
                    if selectedEffort == effort {
                        Label(effort.displayName, systemImage: "checkmark")
                    } else {
                        Text(effort.displayName)
                    }
                }
            }
        } label: {
            pickerLabel(selectedEffort.displayName, icon: "dial.medium")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("응답 생성 effort")
    }

    private func modelButton(_ model: QuickModelOption) -> some View {
        Button {
            selectedModelID = model.id
        } label: {
            if selectedModelID == model.id {
                Label(model.displayName, systemImage: "checkmark")
            } else {
                Text(model.displayName)
            }
        }
    }

    private func constrainSelectedEffort() {
        let efforts = selectedModel.supportedEfforts
        guard !efforts.contains(selectedEffort) else { return }
        selectedEffort = efforts.contains(.high) ? .high : (efforts.first ?? .high)
    }

    private var currentConfiguration: QuickSessionConfiguration {
        QuickSessionConfiguration(
            modelID: selectedModelID,
            effort: selectedEffort,
            proxyEnabled: proxyEnabled
        )
    }

    private func persistSelection() {
        QuickComposerPreferences.save(currentConfiguration)
    }

    private var proxyButton: some View {
        let isCodex = selectedModel.isCodex
        return Button {
            guard modelCatalog.routerAvailable, !isCodex else { return }
            proxyEnabled.toggle()
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(proxyEnabled ? .primary : .secondary.opacity(0.72))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(proxyEnabled ? 0.10 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .disabled(!modelCatalog.routerAvailable || isCodex)
        .help(isCodex ? "Codex 모델은 프록시 세션이 필수입니다" : "세션 내 Claude↔Codex 전환 허용")
    }

    /// Fine의 컨트롤 알약 — 모델·effort·프록시가 같은 높이·라운딩·바탕을 쓴다.
    /// `.borderlessButton` 메뉴는 라벨 배경을 지우므로 메뉴는 `.button` + plain으로 그린다.
    private func pickerLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.secondary.opacity(0.65))
        }
        .foregroundColor(.primary.opacity(0.75))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.05))
        )
        .contentShape(Rectangle())
    }

    private var sessionModeDescription: String {
        if modelCatalog.isLoading {
            return "모델 목록 확인 중"
        }
        if !modelCatalog.routerAvailable {
            return "라우터 오프라인 · Claude 직결만 사용 가능"
        }
        if selectedModel.isCodex || proxyEnabled {
            return "프록시 세션 · /model에서 Claude↔Codex 전환 가능"
        }
        return "Claude 직결 · 세션 안에서 Codex 전환 불가"
    }
}

struct SessionContentView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        AgentTerminalView(session: session)
    }
}
