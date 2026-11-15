import SwiftUI
import AppKit

/// 작업 창 하나: 사이드바 카드와 터미널 영역.
/// 창마다 하나씩 생성된다 — AppState가 여기 살아야 창별 독립 선택이 가능하다.
struct ContentView: View {
    @Binding private var sceneWindowStateId: UUID?
    @StateObject private var appState: AppState
    // The sidebar observes its own activity data. Activity updates must not
    // invalidate the entire window and refocus/re-layout its terminal.
    private let activityScanner = RecentActivityScanner.shared
    @StateObject private var terminalLayout = TerminalLayoutTransition()
    @SceneStorage("workspaceSidebarCompact") private var isSidebarCompact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    init(windowStateId: Binding<UUID?> = .constant(nil)) {
        _sceneWindowStateId = windowStateId
        _appState = StateObject(wrappedValue: AppState(requestedWindowStateId: windowStateId.wrappedValue))
    }

    /// 창별 라이트/다크 — preferredColorScheme은 이 창(씬) 전체에 적용된다
    /// (타이틀바 텍스트·툴바·시트 포함). nil이면 시스템 추종.
    private var preferredScheme: ColorScheme? {
        switch appState.preferredAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var windowTitle: String {
        appState.selectedWorkspace?.name ?? "SpaceManager"
    }

    private var sidebarBinding: Binding<Bool> {
        Binding(get: { isSidebarCompact }, set: { compact in
            guard compact != isSidebarCompact else { return }
            // Suspend the native viewport before SwiftUI starts laying out either
            // panel. Interrupted animations may complete after the next toggle.
            let transition = terminalLayout.begin()
            withAnimation(reduceMotion ? nil : Sidebar.collapseAnimation, completionCriteria: .removed) {
                isSidebarCompact = compact
            } completion: {
                terminalLayout.finish(transition)
            }
        })
    }

    var body: some View {
        workspaceLayout
        // Extend both panels into the titlebar; only the narrow outer frame remains.
        .ignoresSafeArea(.container, edges: .top)
        .background {
            WindowBindingView(
                appState: appState,
                scanner: activityScanner,
                title: windowTitle
            )
                .frame(width: 0, height: 0)
        }
        .environmentObject(appState)
        .environmentObject(terminalLayout)
        .focusedSceneObject(appState)
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $appState.showNewWorkspaceSheet) {
            NewWorkspaceSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showAddProjectSheet) {
            AddProjectSheet()
                .environmentObject(appState)
        }
        .onAppear {
            if appState.shouldCloseOnAppearance {
                dismiss()
                return
            }
            // WindowGroup scene value는 macOS가 창별로 복원한다. 최초/레거시 nil scene에는
            // 실제 claim 결과를 기록해 다음 실행부터 같은 WindowState.id를 돌려받는다.
            if sceneWindowStateId == nil {
                sceneWindowStateId = appState.windowStateId
            }
            RecentActivityScanner.shared.start(owner: appState.windowStateId)
            WindowRestorer.openRemainingWindowsIfNeeded(openWindow)
            WindowOpener.register(openWindow)   // CLI(window.new)가 창을 열 수 있게
        }
        .onDisappear {
            if !appState.shouldCloseOnAppearance {
                RecentActivityScanner.shared.stop(owner: appState.windowStateId)
            }
        }
    }
}

extension ContentView {
    /// 작업 창: 단색 바탕 위에 사이드바 카드와 터미널 카드가 같은 간격으로 떠 있다.
    /// 카드는 그림자 없이 머리카락 선으로 맺는다 — 짙은 바탕에서 그림자는 보이지 않고
    /// 라이트에서는 카드를 무겁게 들어 올렸다.
    private var workspaceLayout: some View {
        HStack(spacing: Self.cardGap) {
            SidebarView(isCompact: sidebarBinding)
                .frame(width: isSidebarCompact ? Sidebar.compactWidth : Sidebar.workspaceWidth)
                .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
                .overlay(cardRim)

            // 터미널 카드의 라운딩·테두리는 TerminalAreaView 안에서 그린다. 탭을 나누면
            // 패널마다 카드가 되어 사이드바 카드와 같은 간격으로 나란히 선다.
            TerminalAreaView()
        }
        .padding(Self.cardGap)
        .background(Color(Chrome.canvas))
    }

    static let cardGap: CGFloat = 8
    static let cardRadius: CGFloat = 12

    private var cardRim: some View {
        RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
            .strokeBorder(Color(Chrome.hairline), lineWidth: 1)
    }
}

/// Sheet for creating a new workspace
struct NewWorkspaceSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var path = ""
    @State private var customName = ""
    @State private var destination = "local"
    @State private var customHost = ""
    @State private var creationError: String?
    @Environment(\.dismiss) var dismiss

    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("New Workspace")
                .font(.headline)

            Picker("실행 위치", selection: $destination) {
                Text("이 Mac").tag("local")
                Text("아치").tag("arch")
                Text("다른 호스트").tag("other")
            }
            .pickerStyle(.segmented)
            .frame(width: 360)

            if destination == "other" {
                TextField("SSH 호스트 별칭", text: $customHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(destination == "local" ? "Mac 작업 폴더" : "원격 작업 폴더")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    TextField(destination == "local" ? "Folder Path" : "~/myworld/project", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)

                    if destination == "local" { Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = true   // 새 프로젝트 폴더를 그 자리에서 만들 수 있게

                        if panel.runModal() == .OK, let url = panel.url {
                            path = url.path
                        }
                    } }
                }

                if destination != "local" {
                    Text("해당 호스트에 있는 폴더 경로를 입력하세요. 파일은 자동으로 이전되지 않습니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 360, alignment: .leading)
                }

                if !path.isEmpty {
                    Text("Name: \(customName.isEmpty ? folderName : customName)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("Custom Name (optional)", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            }

            if let creationError {
                Text(creationError).font(.caption).foregroundColor(.red)
                    .frame(width: 360, alignment: .leading)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    if !path.isEmpty {
                        creationError = appState.createWorkspace(
                            rootPath: path,
                            customName: customName.isEmpty ? nil : customName,
                            remoteHost: destination == "local" ? nil : (destination == "arch" ? "arch" : customHost)
                        )
                        if creationError == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (destination == "other" && customHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(30)
    }
}

/// Sheet for adding a project folder
struct AddProjectSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var path = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Project Folder")
                .font(.headline)

            HStack {
                TextField("Folder Path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)

                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = true

                    if panel.runModal() == .OK, let url = panel.url {
                        path = url.path
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    if !path.isEmpty {
                        appState.addProject(path: path)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty)
            }
        }
        .padding(30)
    }
}
