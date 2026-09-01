import AppKit
import SwiftUI

enum RunnerTheme {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let listBackground = Color(nsColor: .underPageBackgroundColor)
    static let terminalBackground = Color(red: 0.025, green: 0.028, blue: 0.032)
}

struct RunnerLogsView: View {
    @ObservedObject var logs: RunnerLogStore
    @Binding var isPresented: Bool
    let fontSize: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text("Runner Logs")
                    .font(.system(size: fontSize, weight: .semibold, design: .monospaced))

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Hide runner logs")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RunnerTheme.panelBackground)

            Divider()
            terminal
        }
        .background(RunnerTheme.terminalBackground)
        .preferredColorScheme(.dark)
    }

    private var terminal: some View {
        ZStack(alignment: .topLeading) {
            TerminalTextView(snapshot: logs.snapshot, fontSize: fontSize)

            if logs.snapshot.retainedOutput.isEmpty {
                Text("Waiting for output from runners started by Amp Auto Runner…")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .background(RunnerTheme.terminalBackground)
    }
}

struct TerminalTextView: NSViewRepresentable {
    let snapshot: RunnerLogSnapshot
    let fontSize: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.backgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = Self.backgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("Runner log output")

        scrollView.documentView = textView
        context.coordinator.attach(textView)
        context.coordinator.apply(snapshot, fontSize: fontSize)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(snapshot, fontSize: fontSize)
    }

    final class Coordinator {
        private weak var textView: NSTextView?
        private var parser = TerminalTextFormatter.Parser()
        private var renderedRevision: UInt64?
        private var renderedFontSize: Double?

        func attach(_ textView: NSTextView) {
            self.textView = textView
        }

        func apply(_ snapshot: RunnerLogSnapshot, fontSize: Double) {
            guard
                let textView,
                let textStorage = textView.textStorage
            else {
                return
            }

            if renderedRevision == snapshot.revision, renderedFontSize == fontSize {
                return
            }

            let canAppend = renderedFontSize == fontSize
                && renderedRevision.map { $0 &+ 1 == snapshot.revision } == true

            if canAppend {
                let formatted = parser.nsAttributedString(
                    for: snapshot.appendedOutput,
                    fontSize: fontSize
                )
                textStorage.append(formatted)
            } else {
                parser = TerminalTextFormatter.Parser()
                let formatted = parser.nsAttributedString(
                    for: snapshot.retainedOutput,
                    fontSize: fontSize
                )
                textStorage.setAttributedString(formatted)
            }

            trimRenderedHistory(textStorage)
            renderedRevision = snapshot.revision
            renderedFontSize = fontSize

            if !snapshot.retainedOutput.isEmpty {
                textView.scrollToEndOfDocument(nil)
            }
        }

        private func trimRenderedHistory(_ textStorage: NSTextStorage) {
            let overflow = textStorage.length - 200_000
            guard overflow > 0 else {
                return
            }

            let string = textStorage.string as NSString
            let safeRange = string.rangeOfComposedCharacterSequences(
                for: NSRange(location: 0, length: overflow)
            )
            textStorage.deleteCharacters(in: safeRange)
        }
    }

    private static let backgroundColor = NSColor(
        calibratedRed: 0.025,
        green: 0.028,
        blue: 0.032,
        alpha: 1
    )
}

enum TerminalTextFormatter {
    private struct ANSIStyle {
        var foregroundColor = NSColor(white: 0.9, alpha: 1)
        var isBold = false
        var isDim = false
    }

    struct Parser {
        private var style = ANSIStyle()
        private var pendingSequence = ""
        private var pendingCarriageReturn = false

        init() {}

        mutating func nsAttributedString(
            for text: String,
            fontSize: Double = 12
        ) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let input = pendingSequence
                + normalizedLineEndings(in: text)
            pendingSequence = ""
            var remaining = input[...]

            while let escapeIndex = remaining.firstIndex(of: "\u{001B}") {
                TerminalTextFormatter.append(
                    remaining[..<escapeIndex],
                    style: style,
                    fontSize: fontSize,
                    to: result
                )

                let introducerIndex = remaining.index(after: escapeIndex)
                guard introducerIndex < remaining.endIndex else {
                    pendingSequence = String(remaining[escapeIndex...])
                    return result
                }

                switch remaining[introducerIndex] {
                case "[":
                    let sequenceStart = remaining.index(after: introducerIndex)
                    let sequence = remaining[sequenceStart...]
                    guard
                        let terminator = sequence.firstIndex(
                            where: TerminalTextFormatter.isANSITerminator
                        )
                    else {
                        pendingSequence = String(remaining[escapeIndex...])
                        return result
                    }

                    if sequence[terminator] == "m" {
                        let codes = sequence[..<terminator]
                            .split(separator: ";", omittingEmptySubsequences: false)
                            .compactMap { $0.isEmpty ? 0 : Int($0) }
                        TerminalTextFormatter.applySGRCodes(codes, to: &style)
                    }

                    remaining = sequence[sequence.index(after: terminator)...]
                case "]":
                    let sequenceStart = remaining.index(after: introducerIndex)
                    guard
                        let endIndex = TerminalTextFormatter.oscEndIndex(
                            in: remaining[sequenceStart...]
                        )
                    else {
                        pendingSequence = String(remaining[escapeIndex...])
                        return result
                    }
                    remaining = remaining[endIndex...]
                default:
                    remaining = remaining[introducerIndex...]
                }
            }

            TerminalTextFormatter.append(
                remaining,
                style: style,
                fontSize: fontSize,
                to: result
            )
            return result
        }

        private mutating func normalizedLineEndings(in text: String) -> String {
            var input = pendingCarriageReturn ? "\r" + text : text
            pendingCarriageReturn = input.last == "\r"
            if pendingCarriageReturn {
                input.removeLast()
            }
            return input.replacingOccurrences(of: "\r\n", with: "\n")
        }
    }

    static func attributedString(
        for text: String,
        fontSize: Double = 12
    ) -> AttributedString {
        var parser = Parser()
        let formatted = parser.nsAttributedString(for: text, fontSize: fontSize)
        return (try? AttributedString(formatted, including: \.appKit))
            ?? AttributedString(formatted.string)
    }

    private static func append(
        _ text: Substring,
        style: ANSIStyle,
        fontSize: Double,
        to result: NSMutableAttributedString
    ) {
        guard !text.isEmpty else {
            return
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        let color = style.isDim
            ? style.foregroundColor.withAlphaComponent(0.5)
            : style.foregroundColor
        let font = NSFont.monospacedSystemFont(
            ofSize: fontSize,
            weight: style.isBold ? .bold : .regular
        )
        result.append(
            NSAttributedString(
                string: String(text),
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle,
                ]
            )
        )
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

    private static func indexedColor(_ index: Int) -> NSColor {
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

    private static func terminalColor(at index: Int) -> NSColor {
        switch index {
        case 0: return rgbColor(red: 38, green: 41, blue: 46)
        case 1: return rgbColor(red: 245, green: 69, blue: 82)
        case 2: return rgbColor(red: 71, green: 214, blue: 140)
        case 3: return rgbColor(red: 245, green: 194, blue: 82)
        case 4: return rgbColor(red: 89, green: 145, blue: 245)
        case 5: return rgbColor(red: 242, green: 89, blue: 189)
        case 6: return rgbColor(red: 51, green: 209, blue: 217)
        case 7: return rgbColor(red: 209, green: 214, blue: 224)
        case 8: return rgbColor(red: 97, green: 102, blue: 112)
        case 9: return rgbColor(red: 255, green: 99, blue: 110)
        case 10: return rgbColor(red: 97, green: 232, blue: 163)
        case 11: return rgbColor(red: 255, green: 214, blue: 107)
        case 12: return rgbColor(red: 115, green: 171, blue: 255)
        case 13: return rgbColor(red: 255, green: 110, blue: 204)
        case 14: return rgbColor(red: 89, green: 232, blue: 240)
        case 15: return .white
        default: return ANSIStyle().foregroundColor
        }
    }

    private static func xtermComponent(_ component: Int) -> Int {
        component == 0 ? 0 : 55 + (component * 40)
    }

    private static func rgbColor(red: Int, green: Int, blue: Int) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(max(0, min(255, red))) / 255,
            green: CGFloat(max(0, min(255, green))) / 255,
            blue: CGFloat(max(0, min(255, blue))) / 255,
            alpha: 1
        )
    }
}
