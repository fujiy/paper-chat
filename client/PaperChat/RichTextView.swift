import SwiftMath
import SwiftUI

struct ChatRichText: View {
    let source: String

    private var blocks: [ChatRichBlock] {
        ChatRichBlock.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case let .markdown(content):
                    if InlineMathDocument.containsMath(in: content) {
                        ScrollView(.horizontal) {
                            MathTypesetView(
                                latex: InlineMathDocument.latex(from: content),
                                mode: .text,
                                fontSize: 16
                            )
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .scrollIndicators(.automatic)
                    } else {
                        Text(markdown(content))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                case let .math(content):
                    ScrollView(.horizontal) {
                        MathTypesetView(
                            latex: content,
                            mode: .display,
                            fontSize: 17
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .scrollIndicators(.automatic)
                case let .code(language, content):
                    VStack(alignment: .leading, spacing: 5) {
                        if !language.isEmpty {
                            Text(language)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal) {
                            Text(content)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(9)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func markdown(_ content: String) -> AttributedString {
        (try? AttributedString(
            markdown: content,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(content)
    }
}

private struct ChatRichBlock: Identifiable {
    enum Kind {
        case markdown(String)
        case math(String)
        case code(language: String, content: String)
    }

    let id: Int
    let kind: Kind

    static func parse(_ source: String) -> [ChatRichBlock] {
        let lines = source.components(separatedBy: .newlines)
        var result: [ChatRichBlock] = []
        var markdownLines: [String] = []
        var codeLines: [String] = []
        var mathLines: [String] = []
        var codeLanguage = ""
        var inCode = false
        var mathClosingDelimiter: String?

        func append(_ kind: Kind) {
            result.append(ChatRichBlock(id: result.count, kind: kind))
        }

        func flushMarkdown() {
            guard !markdownLines.isEmpty else { return }
            append(.markdown(markdownLines.joined(separator: "\n")))
            markdownLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inCode {
                if trimmed.hasPrefix("```") {
                    append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
                    codeLines = []
                    codeLanguage = ""
                    inCode = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if let closing = mathClosingDelimiter {
                if let range = line.range(of: closing) {
                    mathLines.append(String(line[..<range.lowerBound]))
                    append(.math(mathLines.joined(separator: "\n")))
                    mathLines = []
                    mathClosingDelimiter = nil
                    let remainder = line[range.upperBound...]
                    if !remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                        markdownLines.append(String(remainder))
                    }
                } else {
                    mathLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushMarkdown()
                codeLanguage = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                inCode = true
            } else if let opening = displayMathOpening(in: trimmed) {
                flushMarkdown()
                let afterOpening = String(trimmed.dropFirst(opening.count))
                let closing = opening == "$$" ? "$$" : "\\]"
                if let range = afterOpening.range(of: closing) {
                    append(.math(String(afterOpening[..<range.lowerBound])))
                    let remainder = afterOpening[range.upperBound...]
                    if !remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                        markdownLines.append(String(remainder))
                    }
                } else {
                    if !afterOpening.isEmpty { mathLines.append(afterOpening) }
                    mathClosingDelimiter = closing
                }
            } else if trimmed.isEmpty {
                flushMarkdown()
            } else {
                markdownLines.append(line)
            }
        }

        if inCode {
            append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
        } else if mathClosingDelimiter != nil {
            append(.math(mathLines.joined(separator: "\n")))
        }
        flushMarkdown()
        return result.isEmpty ? [ChatRichBlock(id: 0, kind: .markdown(source))] : result
    }

    private static func displayMathOpening(in line: String) -> String? {
        if line.hasPrefix("$$") { return "$$" }
        if line.hasPrefix("\\[") { return "\\[" }
        return nil
    }
}

private enum InlineMathDocument {
    static func containsMath(in source: String) -> Bool {
        mathRanges(in: source).isEmpty == false
    }

    static func latex(from source: String) -> String {
        let ranges = mathRanges(in: source)
        guard !ranges.isEmpty else { return textLatex(source) }
        var result = ""
        var cursor = source.startIndex
        for range in ranges {
            result += textLatex(String(source[cursor..<range.full.lowerBound]))
            result += String(source[range.content])
            cursor = range.full.upperBound
        }
        result += textLatex(String(source[cursor...]))
        return result
    }

    private struct MathRange {
        let full: Range<String.Index>
        let content: Range<String.Index>
    }

    private static func mathRanges(in source: String) -> [MathRange] {
        var result: [MathRange] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if source[cursor...].hasPrefix("\\("),
               let closing = source.range(of: "\\)", range: source.index(cursor, offsetBy: 2)..<source.endIndex) {
                result.append(MathRange(
                    full: cursor..<closing.upperBound,
                    content: source.index(cursor, offsetBy: 2)..<closing.lowerBound
                ))
                cursor = closing.upperBound
            } else if source[cursor] == "$",
                      !source[cursor...].hasPrefix("$$"),
                      let closing = source[cursor...].dropFirst().firstIndex(of: "$") {
                let contentStart = source.index(after: cursor)
                guard contentStart < closing else {
                    cursor = source.index(after: closing)
                    continue
                }
                result.append(MathRange(
                    full: cursor..<source.index(after: closing),
                    content: contentStart..<closing
                ))
                cursor = source.index(after: closing)
            } else {
                cursor = source.index(after: cursor)
            }
        }
        return result
    }

    private static func textLatex(_ source: String) -> String {
        guard !source.isEmpty else { return "" }
        var value = source
            .replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)", options: .regularExpression)
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "• ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*\d+\.\s+"#, with: "• ", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        value = value
            .replacingOccurrences(of: "\\", with: "\\backslash ")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "_", with: "\\_")
        return "\\text{\(value)}"
    }
}

#if os(macOS)
struct MathTypesetView: NSViewRepresentable {
    let latex: String
    let mode: MTMathUILabelMode
    let fontSize: CGFloat

    func makeNSView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel()
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: MTMathUILabel, context: Context) {
        configure(view)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        nsView.fittingSize
    }

    private func configure(_ view: MTMathUILabel) {
        view.latex = latex
        let font = MTFontManager().font(withName: MathFont.latinModernFont.rawValue, size: fontSize)
        view.font = font
        view.textAlignment = .left
        view.labelMode = mode
        view.textColor = .labelColor
        view.invalidateIntrinsicContentSize()
    }
}
#else
struct MathTypesetView: UIViewRepresentable {
    let latex: String
    let mode: MTMathUILabelMode
    let fontSize: CGFloat

    func makeUIView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel()
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: MTMathUILabel, context: Context) {
        configure(view)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        uiView.intrinsicContentSize
    }

    private func configure(_ view: MTMathUILabel) {
        view.latex = latex
        let font = MTFontManager().font(withName: MathFont.latinModernFont.rawValue, size: fontSize)
        view.font = font
        view.textAlignment = .left
        view.labelMode = mode
        view.textColor = .label
        view.invalidateIntrinsicContentSize()
    }
}
#endif
