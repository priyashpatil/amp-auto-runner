import SwiftUI

struct RunnerLogsView: View {
    @ObservedObject var runners: RunnerManager

    @AppStorage("runnerLogsFontSize") private var fontSize = 12.0

    var body: some View {
        terminal
            .frame(minWidth: 700, minHeight: 460)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        fontSize = max(10, fontSize - 1)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(fontSize <= 10)
                    .help("Decrease font size")

                    Text("\(Int(fontSize)) pt")
                        .font(.caption.monospacedDigit())

                    Button {
                        fontSize = min(18, fontSize + 1)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(fontSize >= 18)
                    .help("Increase font size")
                }
            }
    }

    private var terminal: some View {
        ScrollView {
            Text(displayedOutput)
                .font(.system(size: fontSize, design: .monospaced))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .defaultScrollAnchor(.bottom)
        .background(Color(red: 0.055, green: 0.06, blue: 0.07))
    }

    private var displayedOutput: AttributedString {
        guard !runners.capturedTerminalOutput.isEmpty else {
            var message = AttributedString(
                "Waiting for output from runners started by Amp Auto Runner…"
            )
            message.foregroundColor = Color.white.opacity(0.4)
            return message
        }

        let output = runners.capturedTerminalOutput
            .replacingOccurrences(of: "\r\n", with: "\n")
        return TerminalTextFormatter.attributedString(for: output, fontSize: fontSize)
    }
}

enum TerminalTextFormatter {
    private struct ANSIStyle {
        var foregroundColor = Color.white.opacity(0.9)
        var isBold = false
        var isDim = false
    }

    static func attributedString(
        for text: String,
        fontSize: Double = 12
    ) -> AttributedString {
        ansiAttributedString(for: text, fontSize: fontSize)
    }

    private static func ansiAttributedString(
        for text: String,
        fontSize: Double
    ) -> AttributedString {
        var result = AttributedString()
        var remaining = text[...]
        var style = ANSIStyle()

        while let escapeIndex = remaining.firstIndex(of: "\u{001B}") {
            append(
                remaining[..<escapeIndex],
                style: style,
                fontSize: fontSize,
                to: &result
            )

            let introducerIndex = remaining.index(after: escapeIndex)
            guard introducerIndex < remaining.endIndex else {
                return result
            }

            switch remaining[introducerIndex] {
            case "[":
                let sequenceStart = remaining.index(after: introducerIndex)
                let sequence = remaining[sequenceStart...]
                guard let terminator = sequence.firstIndex(where: isANSITerminator) else {
                    return result
                }

                if sequence[terminator] == "m" {
                    let codes = sequence[..<terminator]
                        .split(separator: ";", omittingEmptySubsequences: false)
                        .compactMap { $0.isEmpty ? 0 : Int($0) }
                    applySGRCodes(codes, to: &style)
                }

                remaining = sequence[sequence.index(after: terminator)...]
            case "]":
                let sequenceStart = remaining.index(after: introducerIndex)
                guard let endIndex = oscEndIndex(in: remaining[sequenceStart...]) else {
                    return result
                }
                remaining = remaining[endIndex...]
            default:
                remaining = remaining[introducerIndex...]
            }
        }

        append(remaining, style: style, fontSize: fontSize, to: &result)
        return result
    }

    private static func append(
        _ text: Substring,
        style: ANSIStyle,
        fontSize: Double,
        to result: inout AttributedString
    ) {
        guard !text.isEmpty else {
            return
        }
        var fragment = AttributedString(String(text))
        fragment.font = .system(
            size: fontSize,
            weight: style.isBold ? .bold : .regular,
            design: .monospaced
        )
        fragment.foregroundColor = style.isDim
            ? style.foregroundColor.opacity(0.5)
            : style.foregroundColor
        result.append(fragment)
    }

    private static func applySGRCodes(_ codes: [Int], to style: inout ANSIStyle) {
        var index = 0

        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0:
                style = ANSIStyle()
            case 1:
                style.isBold = true
            case 2:
                style.isDim = true
            case 22:
                style.isBold = false
                style.isDim = false
            case 30...37:
                style.foregroundColor = terminalColor(at: code - 30)
            case 39:
                style.foregroundColor = ANSIStyle().foregroundColor
            case 90...97:
                style.foregroundColor = terminalColor(at: code - 90 + 8)
            case 38:
                if
                    codes.indices.contains(index + 2),
                    codes[index + 1] == 5
                {
                    style.foregroundColor = indexedColor(codes[index + 2])
                    index += 2
                } else if
                    codes.indices.contains(index + 4),
                    codes[index + 1] == 2
                {
                    style.foregroundColor = rgbColor(
                        red: codes[index + 2],
                        green: codes[index + 3],
                        blue: codes[index + 4]
                    )
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    private static func isANSITerminator(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1
            && character.unicodeScalars.first.map { (0x40...0x7E).contains($0.value) } == true
    }

    private static func oscEndIndex(in sequence: Substring) -> String.Index? {
        let bellIndex = sequence.firstIndex(of: "\u{0007}")
        var stringTerminatorEnd: String.Index?

        if let escapeIndex = sequence.firstIndex(of: "\u{001B}") {
            let slashIndex = sequence.index(after: escapeIndex)
            if slashIndex < sequence.endIndex, sequence[slashIndex] == "\\" {
                stringTerminatorEnd = sequence.index(after: slashIndex)
            }
        }

        if let bellIndex {
            if
                let stringTerminatorEnd,
                stringTerminatorEnd <= bellIndex
            {
                return stringTerminatorEnd
            }
            return sequence.index(after: bellIndex)
        }

        return stringTerminatorEnd
    }

    private static func indexedColor(_ index: Int) -> Color {
        switch index {
        case 0...15:
            return terminalColor(at: index)
        case 16...231:
            let colorIndex = index - 16
            return rgbColor(
                red: xtermComponent(colorIndex / 36),
                green: xtermComponent((colorIndex % 36) / 6),
                blue: xtermComponent(colorIndex % 6)
            )
        case 232...255:
            let component = 8 + ((index - 232) * 10)
            return rgbColor(red: component, green: component, blue: component)
        default:
            return ANSIStyle().foregroundColor
        }
    }

    private static func terminalColor(at index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.15, green: 0.16, blue: 0.18)
        case 1: return Color(red: 0.96, green: 0.27, blue: 0.32)
        case 2: return Color(red: 0.28, green: 0.84, blue: 0.55)
        case 3: return Color(red: 0.96, green: 0.76, blue: 0.32)
        case 4: return Color(red: 0.35, green: 0.57, blue: 0.96)
        case 5: return Color(red: 0.95, green: 0.35, blue: 0.74)
        case 6: return Color(red: 0.20, green: 0.82, blue: 0.85)
        case 7: return Color(red: 0.82, green: 0.84, blue: 0.88)
        case 8: return Color(red: 0.38, green: 0.40, blue: 0.44)
        case 9: return Color(red: 1.00, green: 0.39, blue: 0.43)
        case 10: return Color(red: 0.38, green: 0.91, blue: 0.64)
        case 11: return Color(red: 1.00, green: 0.84, blue: 0.42)
        case 12: return Color(red: 0.45, green: 0.67, blue: 1.00)
        case 13: return Color(red: 1.00, green: 0.43, blue: 0.80)
        case 14: return Color(red: 0.35, green: 0.91, blue: 0.94)
        case 15: return .white
        default: return ANSIStyle().foregroundColor
        }
    }

    private static func xtermComponent(_ component: Int) -> Int {
        component == 0 ? 0 : 55 + (component * 40)
    }

    private static func rgbColor(red: Int, green: Int, blue: Int) -> Color {
        Color(
            red: Double(max(0, min(255, red))) / 255,
            green: Double(max(0, min(255, green))) / 255,
            blue: Double(max(0, min(255, blue))) / 255
        )
    }
}
