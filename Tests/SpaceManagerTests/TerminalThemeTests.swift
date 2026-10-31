import Foundation
import XCTest
@testable import GhosttyTerminal
@testable import SpaceManager

final class TerminalThemeTests: XCTestCase {
    static let ansi16 = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow",
        "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
    ]

    static func contrast(_ a: String, _ b: String) throws -> Double {
        func luminance(_ hex: String) throws -> Double {
            let value = try XCTUnwrap(Int(hex.dropFirst(), radix: 16))
            func channel(_ shift: Int) -> Double {
                let c = Double((value >> shift) & 0xff) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (x, y) = (try luminance(a), try luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testBothPalettesDefineEveryANSISlot() throws {
        for palette in [TerminalPalette.quickLight, .workspaceDark] {
            XCTAssertEqual(Set(Self.ansi16).subtracting(palette.colors.keys), [])
            // 16칸이 모두 Ghostty 설정의 palette 줄이 된다.
            let config = GhosttyConfigText.make(theme: palette.ghosttyTheme)
            XCTAssertEqual(config.components(separatedBy: "\npalette = ").count - 1, 16)
        }
        XCTAssertEqual(TerminalPalette.quickLight.colors["background"], "#ffffff")
        // 워크스페이스 터미널 카드(GlassSurfacePolicy.terminalCardColor)와 같은 바탕.
        XCTAssertEqual(TerminalPalette.workspaceDark.colors["background"], "#1e1e1e")
    }

    /// Claude `*-ansi` 테마의 실제 출력: 97은 본문 강조, 37은 보조 글자, 94는 인라인 코드·링크.
    /// 이름이 아니라 역할로 읽혀야 한다 — 라이트에서 97이 희면 흰 바탕에서 사라진다.
    func testClaudeANSIRolesReadOnBothBackgrounds() throws {
        for palette in [TerminalPalette.quickLight, .workspaceDark] {
            let c = palette.colors
            let bg = try XCTUnwrap(c["background"])
            let emphasis = try Self.contrast(XCTUnwrap(c["brightWhite"]), bg)
            let body = try Self.contrast(XCTUnwrap(c["foreground"]), bg)
            let secondary = try Self.contrast(XCTUnwrap(c["white"]), bg)
            XCTAssertGreaterThanOrEqual(emphasis, body)
            XCTAssertGreaterThan(body, secondary)
            XCTAssertGreaterThanOrEqual(secondary, 4.5)
            for key in ["red", "green", "yellow", "blue", "magenta", "cyan", "brightBlue", "brightRed"] {
                XCTAssertGreaterThanOrEqual(try Self.contrast(XCTUnwrap(c[key]), bg), 4.5, "\(bg) \(key)")
            }
            // 팔레트 색은 위에서 모두 4.5를 넘는다. 그래서 어두운 쪽은 엔진의 보정을 끈다 — Ghostty는 모자란
            // 글자를 순백으로 바꿔 Claude mod의 흐린 회색을 흰색으로 만들었다(GhosttyContrastTests).
            XCTAssertEqual(palette.minimumContrastRatio, palette == .workspaceDark ? 1 : 4.5)
        }
    }
}
