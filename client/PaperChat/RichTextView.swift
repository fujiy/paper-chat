import SwiftMath
import SwiftUI

struct ChatRichText: View {
    let source: String
    var isStreaming = false
    let onOpenPage: (Int) -> Void

    private var blocks: [ChatRichBlock] {
        ChatRichBlock.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case let .markdown(content):
                    if isStreaming {
                        if InlineMathDocument.containsMath(in: content) {
                            InlineMathText(
                                source: content,
                                fontSize: 16,
                                rendersMarkdown: false
                            )
                        } else {
                            Text(content)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    } else {
                        let linkedContent = PageCitationLinks.markdown(in: content)
                        if InlineMathDocument.containsMath(in: linkedContent) {
                            InlineMathText(source: linkedContent, fontSize: 16)
                        } else {
                            Text(markdown(linkedContent))
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                case let .plain(content):
                    Text(content)
                        .font(.body)
                        .textSelection(.enabled)
                case let .math(content):
                    let preparedMath = MathLatexCompatibility.prepareDisplay(content)
                    ScrollView(.horizontal) {
                        if MathLatexCompatibility.canParse(preparedMath.latex) {
                            MathTypesetView(
                                latex: preparedMath.latex,
                                mode: .display,
                                fontSize: 17
                            )
                            .padding(preparedMath.isBoxed ? 5 : 0)
                            .overlay {
                                if preparedMath.isBoxed {
                                    Rectangle()
                                        .stroke(.primary, lineWidth: 1)
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        } else {
                            Text("\\[\n\(content)\n\\]")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .defaultScrollAnchor(.center, for: .alignment)
                    .frame(maxWidth: .infinity)
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
        .environment(\.openURL, OpenURLAction { url in
            guard let page = PageCitationLinks.pageNumber(from: url) else {
                return .systemAction
            }
            onOpenPage(page)
            return .handled
        })
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

private enum PageCitationLinks {
    private static let scheme = "paperchat"

    static func markdown(in source: String) -> String {
        source.replacingOccurrences(
            of: #"\[p\.\s*(\d+)\](?!\()"#,
            with: #"[p. $1](paperchat://page/$1)"#,
            options: .regularExpression
        )
    }

    static func pageNumber(from url: URL) -> Int? {
        guard url.scheme == scheme, url.host == "page",
              let page = Int(url.lastPathComponent), page > 0 else {
            return nil
        }
        return page
    }
}

private struct InlineMathText: View {
    let source: String
    let fontSize: CGFloat
    var rendersMarkdown = true

    var body: some View {
        InlineMathDocument.text(
            from: source,
            fontSize: fontSize,
            rendersMarkdown: rendersMarkdown
        )
            .font(.body)
            .textSelection(.enabled)
    }
}

private struct ChatRichBlock: Identifiable {
    enum Kind {
        case markdown(String)
        case plain(String)
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
        var unfinishedMathSource: String?
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
                    unfinishedMathSource = nil
                    let remainder = line[range.upperBound...]
                    if !remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                        markdownLines.append(String(remainder))
                    }
                } else {
                    mathLines.append(line)
                    unfinishedMathSource? += "\n" + line
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
                    unfinishedMathSource = line
                }
            } else if trimmed.isEmpty {
                flushMarkdown()
            } else {
                markdownLines.append(line)
            }
        }

        if inCode {
            append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
        } else if let unfinishedMathSource {
            append(.plain(unfinishedMathSource))
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

private enum MathLatexCompatibility {
    struct DisplayMath {
        let latex: String
        let isBoxed: Bool
    }

    static func prepareDisplay(_ latex: String) -> DisplayMath {
        if let unboxed = unwrapOuterBox(in: latex) {
            return DisplayMath(latex: normalize(unboxed), isBoxed: true)
        }
        return DisplayMath(latex: normalize(latex), isBoxed: false)
    }

    static func normalize(_ latex: String) -> String {
        let normalized = latex
            .replacingOccurrences(of: "\\operatorname*", with: "\\mathrm")
            .replacingOccurrences(of: "\\operatorname", with: "\\mathrm")
            // SwiftMath does not support nested \boxed commands. Keeping the
            // grouped argument is preferable to dropping the entire equation.
            .replacingOccurrences(of: "\\boxed", with: "")
        return normalized.replacingOccurrences(
            of: #"\\(?:bigg|Bigg|big|Big)[lr]?(?=\s*[\(\)\[\]\{\}\|])"#,
            with: "",
            options: .regularExpression
        )
    }

    static func canParse(_ latex: String) -> Bool {
        var error: NSError?
        return MTMathListBuilder.build(fromString: latex, error: &error) != nil
            && error == nil
    }

    private static func unwrapOuterBox(in latex: String) -> String? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\\boxed{"
        guard trimmed.hasPrefix(prefix) else { return nil }

        let contentStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        var depth = 1
        var cursor = contentStart
        while cursor < trimmed.endIndex {
            let character = trimmed[cursor]
            if character == "{", !isEscaped(at: cursor, in: trimmed) {
                depth += 1
            } else if character == "}", !isEscaped(at: cursor, in: trimmed) {
                depth -= 1
                if depth == 0 {
                    let trailing = trimmed[trimmed.index(after: cursor)...]
                    guard trailing.allSatisfy(\.isWhitespace) else { return nil }
                    return String(trimmed[contentStart..<cursor])
                }
            }
            cursor = trimmed.index(after: cursor)
        }
        return nil
    }

    private static func isEscaped(at index: String.Index, in source: String) -> Bool {
        var slashCount = 0
        var cursor = index
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount.isMultiple(of: 2) == false
    }
}

@MainActor
private enum InlineMathDocument {
    static func containsMath(in source: String) -> Bool {
        mathRanges(in: source).isEmpty == false
    }

    static func text(
        from source: String,
        fontSize: CGFloat,
        rendersMarkdown: Bool = true
    ) -> Text {
        let ranges = mathRanges(in: source)
        guard !ranges.isEmpty else {
            return rendersMarkdown ? Text(markdown(source)) : Text(source)
        }
        var result = Text("")
        var cursor = source.startIndex
        for range in ranges {
            let prefix = String(source[cursor..<range.full.lowerBound])
            result = result + (rendersMarkdown ? Text(markdown(prefix)) : Text(prefix))
            let latex = String(source[range.content])
            if let renderedMath = mathImage(latex: latex, fontSize: fontSize) {
                result = result + Text(renderedMath.image)
                    .baselineOffset(-renderedMath.descent)
            } else {
                let original = String(source[range.full])
                result = result + Text(original).foregroundColor(.red)
            }
            cursor = range.full.upperBound
        }
        let suffix = String(source[cursor...])
        result = result + (rendersMarkdown ? Text(markdown(suffix)) : Text(suffix))
        return result
    }

    private static func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(source)
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

    private struct RenderedMath {
        let image: Image
        let descent: CGFloat
    }

    private static func mathImage(latex: String, fontSize: CGFloat) -> RenderedMath? {
        #if os(macOS)
        let textColor = NSColor.labelColor
        #else
        let textColor = UIColor.label
        #endif

        var renderer = MathImage(
            latex: MathLatexCompatibility.normalize(latex),
            fontSize: fontSize,
            textColor: textColor,
            labelMode: .text,
            textAlignment: .left
        )
        renderer.contentInsets = .init(top: 0, left: 2, bottom: 0, right: 2)
        let (_, image, layout) = renderer.asImage()
        guard let image, let layout else { return nil }

        #if os(macOS)
        let swiftUIImage = Image(nsImage: image)
        #else
        let swiftUIImage = Image(uiImage: image)
        #endif
        return RenderedMath(image: swiftUIImage, descent: layout.descent)
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
        view.latex = MathLatexCompatibility.normalize(latex)
        let font = MTFontManager().font(withName: MathFont.latinModernFont.rawValue, size: fontSize)
        view.font = font
        view.textAlignment = mode == .display ? .center : .left
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
        view.latex = MathLatexCompatibility.normalize(latex)
        let font = MTFontManager().font(withName: MathFont.latinModernFont.rawValue, size: fontSize)
        view.font = font
        view.textAlignment = mode == .display ? .center : .left
        view.labelMode = mode
        view.textColor = .label
        view.invalidateIntrinsicContentSize()
    }
}
#endif
