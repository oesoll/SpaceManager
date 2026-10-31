import Foundation

/// `sm reveal NAME@HOST`: Fine 노치의 알림을 누르면 Fine이 이것을 부른다(10/31, harness-w1-2와 정한 길).
/// SEOL이 노치에서 "나를 필요로 하는" 에이전트를 누르면, 그 에이전트가 보이는 패널이 앞에 나와 바로 답할 수 있다.
extension AppState {
    /// 이 창에서 그 워크스페이스를 고르고, 그 세션이 보이는 패널로 포커스와 키를 옮긴다. 어느 패널에도 없으면
    /// 새 탭에 붙인다. 원격 배치는 고른 뒤에야 따라오기 시작하므로, 배치가 들어올 때까지 잠깐 기다린다.
    func reveal(session name: String, in workspace: Workspace, layoutKey key: String, pane hint: String?,
                completion: @escaping (Result<(tab: String, pane: String), SessionLayer.Failure>) -> Void) {
        if selectedWorkspace?.id != workspace.id { selectWorkspace(workspace) }
        let deadline = Date().addingTimeInterval(8)
        var openedTab = false
        var finished = false
        func finish(_ result: Result<(tab: String, pane: String), SessionLayer.Failure>) {
            guard !finished else { return }
            finished = true
            completion(result)
        }
        func paneShowing(in layout: WorkspaceLayout) -> String? {
            if let hint, layout.panes[hint] != nil { return hint }
            return layout.panes.first { $0.value.session?.caseInsensitiveCompare(name) == .orderedSame }?.key
        }
        func attempt() {
            guard !finished else { return }
            if let layout = LayoutDirectory.shared.layouts[key] {
                if let pane = paneShowing(in: layout) {
                    focusLayoutPane(pane, in: layout)
                    let terminal = layoutTerminals.session(for: pane, in: layout, workspace: workspace)
                    // 다른 탭이었다면 그 탭이 앞에 나온 다음 차례에 키를 받는다(숨은 탭의 터미널은 키를 받지 않는다).
                    DispatchQueue.main.async { terminal.focusTerminal() }
                    finish(.success((layout.tab(containing: pane)?.id ?? "", pane)))
                    return
                }
                if !openedTab {
                    openedTab = true
                    runLayoutCommand(["tab", "new", "--attach", name], layout: layout) { result in
                        if case .failure(let failure) = result { finish(.failure(failure)) }
                        // 성공이면 배치 파일(원격은 watch)이 곧 새 탭을 가져온다 — 아래에서 다시 찾는다.
                    }
                }
            }
            guard Date() < deadline else {
                finish(.failure(.init(message: "\(key)의 배치에서 \(name) 패널을 찾지 못했습니다")))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: attempt)
        }
        attempt()
    }
}
