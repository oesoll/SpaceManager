import Foundation

/// xterm.js에 전달하는 창 종류별 팔레트.
struct TerminalPalette: Equatable {
    let colors: [String: String]
    /// 팔레트가 닿지 않는 truecolor(Codex의 문법 강조 등)도 읽히게 xterm이 글자 명도를 보정한다.
    var minimumContrastRatio: Double = 4.5

    /// ANSI 16색은 "색 이름"이 아니라 "역할"로 칠한다 — Fine과 같은 팔레트다.
    /// Claude의 `*-ansi` 테마는 본문 강조를 97, 보조 글자를 37, 인라인 코드·링크를 94,
    /// 강조색을 91, 문법 강조를 31/33/34/36으로 낸다(2026-10 실제 캡처). 그래서 37은 회색,
    /// 97은 가장 밝은 글자다. 강조는 glamour처럼 차분한 몇 가지 색만 둔다.
    /// 배경 #1e1e1e는 기존 워크스페이스 터미널 카드와 같다.
    static let workspaceDark = TerminalPalette(colors: [
        "background": "#1e1e1e",
        // 본문은 glamour 본문색(xterm 252)과 같은 밝기다. 순백에 가까운 글자는 짙은 바탕에서
        // 번져 보여 오래 읽으면 눈이 먼저 지친다. 강조(97)는 그보다 한 단만 밝다.
        "foreground": "#d0d0d2",
        "cursor": "#e0e0e2",
        "cursorAccent": "#1e1e1e",
        "selectionBackground": "#3a3f4b",
        "selectionInactiveBackground": "#2e3138",
        "selectionForeground": "#ececee",
        "black": "#48484c",
        // 강조색은 채도를 한 단 눌렀다 — 문법 강조와 Claude 강조색이 본문보다 먼저
        // 눈에 걸리지 않게. 색상(hue)은 그대로라 역할 구분은 남는다.
        "red": "#df9284",
        "green": "#97c99b",
        "yellow": "#d8c08a",
        "blue": "#8badea",
        "magenta": "#c2a7e6",
        "cyan": "#82c2c6",
        "white": "#9d9da3",
        // Claude가 제출한 프롬프트의 면(ANSI 100). 바탕보다 한 단 밝다.
        "brightBlack": "#2c2c2e",
        "brightRed": "#e0936f",
        "brightGreen": "#a6d3a8",
        "brightYellow": "#e3cf9f",
        "brightBlue": "#9cbcef",
        "brightMagenta": "#cdb6ee",
        "brightCyan": "#98d0cd",
        "brightWhite": "#ececee",
    ])

    /// 같은 역할의 라이트판. 97(강조)은 흰 바탕에서 사라지지 않게 검정에 가깝고,
    /// 37(보조)은 회색이다.
    static let quickLight = TerminalPalette(colors: [
        "background": "#ffffff",
        // 흰 바탕의 순흑은 대비가 지나쳐 번쩍인다. 본문은 한 단 누르고, 강조(97)가 더 짙다.
        "foreground": "#2a2a2e",
        "cursor": "#2a2a2e",
        "cursorAccent": "#ffffff",
        "selectionBackground": "#c2dbff",
        "selectionInactiveBackground": "#dde7f4",
        "selectionForeground": "#000000",
        "black": "#1d1d1f",
        "red": "#b5412c",
        "green": "#2f7d3b",
        "yellow": "#93650a",
        "blue": "#2457b8",
        "magenta": "#8a46b0",
        "cyan": "#0f7782",
        "white": "#6e6e73",
        "brightBlack": "#eeeeec",
        "brightRed": "#c2552f",
        "brightGreen": "#2f8a45",
        "brightYellow": "#9c6d00",
        "brightBlue": "#2f6bd6",
        "brightMagenta": "#9a4fc4",
        "brightCyan": "#11808c",
        "brightWhite": "#111113",
    ])

    /// 라이트 작업 창은 Quick과 같은 라이트 역할 팔레트를 쓴다.
    static let workspaceLight = quickLight

    var json: String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: colors,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
