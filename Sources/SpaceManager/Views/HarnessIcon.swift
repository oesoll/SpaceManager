import SwiftUI

/// 에이전트 하니스의 로고(Claude Code, Codex). Fine의 HarnessIcons와 같은 그림이다(24×24 viewBox, 한 경로,
/// even-odd). 자산 번들을 들이지 않으려고 경로를 코드에 담았다 — 앱은 리소스 번들 없이 패키징된다.
/// 모르는 하니스는 SF Symbol의 터미널로 그린다.
struct HarnessIcon: View {
    let kind: String

    var body: some View {
        if let shape = HarnessGlyph(kind: kind) {
            shape.fill(style: FillStyle(eoFill: true))
        } else {
            Image(systemName: "terminal")
                .resizable()
                .scaledToFit()
        }
    }
}

struct HarnessGlyph: Shape {
    private let source: String

    init?(kind: String) {
        switch kind {
        case "claude": source = Self.claude
        case "codex": source = Self.codex
        default: return nil
        }
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let path = SVGPath.parse(source)
        return path.applying(CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
            .scaledBy(x: scale, y: scale))
    }

    private static let claude = "M4.709 15.955 9.429 13.308 9.509 13.078 9.429 12.95H9.2L8.41 12.902L5.712 12.829L3.373 12.732L1.107 12.61L0.536 12.489L0 11.784L0.055 11.432L0.535 11.111L1.221 11.171L2.741 11.274L5.019 11.432L6.671 11.529L9.12 11.784H9.509L9.564 11.627L9.43 11.529L9.327 11.432L6.969 9.836L4.417 8.148L3.081 7.176L2.357 6.685L1.993 6.223L1.835 5.215L2.491 4.493L3.372 4.553L3.597 4.614L4.49 5.3L6.398 6.776L8.889 8.609L9.254 8.913L9.399 8.81L9.418 8.737L9.254 8.463L7.899 6.017L6.453 3.527L5.809 2.495L5.639 1.876C5.574 1.638 5.539 1.393 5.535 1.147L6.283 0.134L6.696 0L7.692 0.134L8.112 0.498L8.732 1.912L9.734 4.141L11.289 7.171L11.745 8.069L11.988 8.901L12.079 9.156H12.237V9.01L12.365 7.304L12.602 5.209L12.832 2.514L12.912 1.754L13.288 0.844L14.035 0.352L14.619 0.632L15.099 1.317L15.032 1.761L14.746 3.612L14.187 6.515L13.823 8.457H14.035L14.278 8.215L15.263 6.909L16.915 4.845L17.645 4.025L18.495 3.121L19.042 2.69H20.075L20.835 3.819L20.495 4.985L19.431 6.332L18.55 7.474L17.286 9.174L16.496 10.534L16.569 10.644L16.757 10.624L19.613 10.018L21.156 9.738L22.997 9.423L23.83 9.811L23.921 10.206L23.593 11.013L21.624 11.499L19.315 11.961L15.876 12.774L15.834 12.804L15.883 12.865L17.432 13.011L18.094 13.047H19.716L22.736 13.272L23.526 13.794L24 14.432L23.921 14.917L22.706 15.537L21.066 15.148L17.237 14.238L15.925 13.909H15.743V14.019L16.836 15.087L18.842 16.897L21.351 19.227L21.478 19.805L21.156 20.26L20.816 20.211L18.611 18.554L17.76 17.807L15.834 16.187H15.706V16.357L16.15 17.006L18.495 20.527L18.617 21.607L18.447 21.96L17.839 22.173L17.171 22.051L15.797 20.126L14.382 17.959L13.239 16.016L13.099 16.096L12.425 23.35L12.109 23.72L11.38 24L10.773 23.539L10.451 22.792L10.773 21.316L11.162 19.392L11.477 17.862L11.763 15.962L11.933 15.33L11.921 15.288L11.781 15.306L10.347 17.273L8.167 20.218L6.441 22.063L6.027 22.227L5.31 21.857L5.377 21.195L5.778 20.606L8.166 17.57L9.606 15.688L10.536 14.602L10.53 14.444H10.475L4.132 18.56L3.002 18.706L2.515 18.25L2.576 17.504L2.807 17.261L4.715 15.949L4.709 15.955V15.955Z"
    private static let codex = "M8.086 0.457C9.049 0.061 10.098 -0.082 11.132 0.042C12.465 0.195 13.653 0.762 14.696 1.742C14.725 1.769 14.765 1.78 14.803 1.771C16.211 1.425 17.565 1.547 18.864 2.137L18.927 2.167L19.081 2.243C20.438 2.946 21.411 4.013 21.999 5.441C22.277 6.12 22.417 6.829 22.42 7.567C22.44 8.117 22.379 8.666 22.24 9.198C22.226 9.253 22.241 9.312 22.28 9.353C23.066 10.15 23.613 11.152 23.858 12.244C24.243 14.145 23.848 15.859 22.675 17.384L22.493 17.604C21.716 18.494 20.696 19.137 19.559 19.455C19.509 19.47 19.468 19.508 19.451 19.557C19.196 20.293 18.94 20.921 18.464 21.549C17.265 23.131 15.502 24.011 13.516 24C11.933 23.992 10.53 23.413 9.306 22.264C9.268 22.229 9.215 22.217 9.166 22.232C8.648 22.399 8.126 22.423 7.562 22.417C6.661 22.41 5.773 22.197 4.967 21.795C4.123 21.376 3.388 20.766 2.821 20.014C2.618 19.745 2.417 19.492 2.27 19.193C2.067 18.781 1.902 18.352 1.775 17.91C1.509 16.907 1.503 15.852 1.758 14.846C1.766 14.822 1.769 14.797 1.766 14.772C1.761 14.747 1.748 14.725 1.729 14.708C1.113 14.084 0.641 13.333 0.349 12.506C0.155 11.997 0.043 11.461 0.016 10.917C-0.032 10.201 0.031 9.482 0.204 8.785C0.654 7.301 1.513 6.137 2.781 5.292C3.063 5.104 3.331 4.958 3.583 4.854C3.869 4.734 4.156 4.634 4.444 4.55C4.486 4.538 4.519 4.505 4.531 4.463C4.749 3.678 5.125 2.945 5.635 2.31C6.315 1.464 7.132 0.846 8.086 0.457ZM7.282 8.307C7.049 7.9 6.531 7.759 6.125 7.992C5.718 8.224 5.576 8.742 5.809 9.149L7.503 12.114L5.815 14.962C5.6 15.363 5.739 15.862 6.131 16.094C6.522 16.326 7.027 16.207 7.275 15.826L9.215 12.554C9.371 12.291 9.373 11.965 9.222 11.7L7.282 8.307V8.307ZM12.728 14.547C12.279 14.574 11.929 14.945 11.929 15.395C11.929 15.844 12.279 16.215 12.728 16.242H17.576C18.028 16.22 18.384 15.847 18.384 15.394C18.384 14.941 18.028 14.568 17.576 14.546H12.728L12.728 14.547Z"
}

/// 절대 좌표 M L H V C Z만 읽는 SVG 경로 해석기(위 두 로고가 쓰는 명령이 이것뿐이다). M 뒤에 이어진 좌표는 L로 읽는다.
enum SVGPath {
    static func parse(_ text: String) -> Path {
        var path = Path()
        var tokens: [String] = []
        var number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for ch in text {
            if ch.isLetter && ch != "e" && ch != "E" { flush(); tokens.append(String(ch)) }
            else if ch == " " || ch == "," { flush() }
            else if ch == "-" && !number.isEmpty && !number.hasSuffix("e") && !number.hasSuffix("E") { flush(); number = "-" }
            else { number.append(ch) }
        }
        flush()
        var i = 0, command = "M", current = CGPoint.zero
        func next() -> CGFloat? {
            guard i < tokens.count, let value = Double(tokens[i]) else { return nil }
            i += 1
            return CGFloat(value)
        }
        while i < tokens.count {
            if Double(tokens[i]) == nil { command = tokens[i]; i += 1 }
            switch command {
            case "M":
                guard let x = next(), let y = next() else { return path }
                current = CGPoint(x: x, y: y); path.move(to: current); command = "L"
            case "L":
                guard let x = next(), let y = next() else { return path }
                current = CGPoint(x: x, y: y); path.addLine(to: current)
            case "H":
                guard let x = next() else { return path }
                current.x = x; path.addLine(to: current)
            case "V":
                guard let y = next() else { return path }
                current.y = y; path.addLine(to: current)
            case "C":
                guard let x1 = next(), let y1 = next(), let x2 = next(), let y2 = next(), let x = next(), let y = next() else { return path }
                current = CGPoint(x: x, y: y)
                path.addCurve(to: current, control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            case "Z", "z":
                // 숫자가 뒤따르면(규칙 밖) 거기서 멈춘다 — 같은 명령을 되풀이하며 멈추지 않는 일이 없게.
                path.closeSubpath(); command = ""
            default:
                return path
            }
        }
        return path
    }
}
