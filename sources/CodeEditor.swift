import SwiftUI
import UIKit

enum Vocab {
    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    static let globals: [String] =
        words("False None True and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield")
        + words("abs all any bin bool bytes callable chr dict dir divmod enumerate eval exec filter float format frozenset getattr globals hasattr hash hex id input int isinstance issubclass iter len list locals map max min next object oct open ord pow print property range repr reversed round set setattr slice sorted staticmethod str sum super tuple type vars zip")
        + words("Exception ValueError TypeError KeyError IndexError RuntimeError StopIteration KeyboardInterrupt ZeroDivisionError AttributeError ImportError NameError OSError")
        + words("math random time json os sys datetime re string numpy np collections itertools functools threading statistics decimal fractions copy textwrap base64 hashlib uuid pathlib typing dataclasses enum csv sqlite3 urllib heapq bisect pilIOS pyUI colorama sdl2")
        + words("ui label entry button clear")

    static let generic: [String] = words("append extend insert remove pop sort reverse index count join split strip lstrip rstrip replace upper lower title capitalize format startswith endswith find keys values items get update add copy clear isdigit isalpha")

    private static let npWords = words("array arange linspace zeros ones empty full eye identity random sum mean median std var min max argmax argmin dot matmul sqrt exp log sin cos tan abs reshape shape concatenate stack vstack hstack where sort argsort unique cumsum prod transpose linalg pi e inf nan ndarray float64 int64 round floor ceil clip diff any all isnan zeros_like ones_like")

    static let members: [String: [String]] = [
        "numpy": npWords,
        "np": npWords,
        "math": words("pi e tau inf nan sqrt pow exp log log2 log10 sin cos tan asin acos atan atan2 sinh cosh tanh floor ceil fabs factorial gcd lcm hypot degrees radians isclose isnan isinf trunc comb perm prod dist fsum"),
        "random": words("random randint randrange choice choices shuffle sample uniform gauss seed betavariate expovariate"),
        "time": words("time sleep monotonic perf_counter process_time strftime localtime gmtime ctime"),
        "json": words("dumps loads dump load"),
        "os": words("getcwd listdir path environ mkdir remove rename getenv sep walk"),
        "sys": words("argv path version platform exit stdout stderr modules maxsize"),
        "datetime": words("datetime date time timedelta timezone"),
        "string": words("ascii_letters ascii_lowercase ascii_uppercase digits punctuation whitespace"),
        "ui": words("label entry button clear"),
        "pilIOS": words("Image new save open load draw pixel line rectangle ellipse text resize crop rotate paste getpixel putpixel"),
        "colorama": words("Fore Back Style init just_fix_windows_console RESET BLACK RED GREEN YELLOW BLUE MAGENTA CYAN WHITE LIGHTBLACK_EX LIGHTRED_EX LIGHTGREEN_EX LIGHTYELLOW_EX LIGHTBLUE_EX LIGHTMAGENTA_EX LIGHTCYAN_EX LIGHTWHITE_EX BRIGHT DIM NORMAL"),
        "sdl2": words("SDL_Init SDL_Quit SDL_GetError SDL_GetVersion SDL_INIT_VIDEO SDL_INIT_AUDIO SDL_CreateWindow SDL_DestroyWindow SDL_PollEvent SDL_Delay SDL_WINDOW_SHOWN SDL_WINDOWPOS_CENTERED"),
    ]

    static let symbols: [String] = ["(", ")", ":", "\"", "'", "=", "[", "]", "{", "}", "_", "#", ".", ",", "+", "-", "*", "/", "%", "<", ">"]
}

// The gutter uses the editor's actual line fragments, so wrapped lines and
// scrolling do not change which source line a number belongs to.
final class LineNumberGutter: UIView {
    weak var textView: UITextView?
    var lineStarts = [0]

    func updateLines() {
        guard let textView = textView else { return }
        let source = (textView.text ?? "") as NSString
        lineStarts = [0]
        var location = 0
        while location < source.length {
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: location, length: 0))
            guard end > location else { break }
            if end < source.length || contentsEnd < end { lineStarts.append(end) }
            location = end
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let textView = textView else { return }
        let layout = textView.layoutManager
        let font = textView.font ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.secondaryLabel
        ]
        let length = (textView.text as NSString).length
        for (index, start) in lineStarts.enumerated() {
            let fragment: CGRect
            if start < length {
                let glyph = layout.glyphIndexForCharacter(at: start)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                fragment = layout.extraLineFragmentRect
            }
            let y = fragment.minY + textView.textContainerInset.top - textView.contentOffset.y
            if y > bounds.maxY { break }
            if y + font.lineHeight < 0 { continue }
            let number = String(index + 1) as NSString
            let width = number.size(withAttributes: attributes).width
            number.draw(at: CGPoint(x: bounds.width - width - 5, y: y), withAttributes: attributes)
        }
    }
}

final class EditorTextView: UITextView {
    let gutter = LineNumberGutter()
    var gutterWidth: CGFloat = 34 {
        didSet {
            textContainerInset.left = gutterWidth + 6
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Subviews of a scroll view use content coordinates. Pin the gutter to
        // the visible viewport without forcing another text layout from draw().
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y,
                              width: gutterWidth, height: bounds.height)
        gutter.setNeedsDisplay()
    }
}

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 14
    var autoIndent = true
    var findRequest = 0
    var lineRequest = 0
    var targetLine = 1

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EditorTextView {
        // Start in TextKit 1, which is also used to draw the gutter. Switching
        // layout engines during drawing can invalidate UITextView's scroll size.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layout.addTextContainer(textContainer)
        storage.addLayoutManager(layout)
        let tv = EditorTextView(frame: .zero, textContainer: textContainer)
        let gutter = tv.gutter
        gutter.textView = tv
        gutter.backgroundColor = .secondarySystemBackground
        gutter.isUserInteractionEnabled = false
        tv.addSubview(gutter)
        tv.delegate = context.coordinator
        tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textColor = .label
        tv.backgroundColor = .systemBackground
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.spellCheckingType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.isScrollEnabled = true
        tv.isFindInteractionEnabled = true
        tv.accessibilityIdentifier = "codeEditor"
        tv.showsVerticalScrollIndicator = true
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.textContainerInset = UIEdgeInsets(top: 8, left: tv.gutterWidth + 6, bottom: 8, right: 6)
        tv.text = text
        context.coordinator.tv = tv
        context.coordinator.gutter = gutter
        tv.inputAccessoryView = context.coordinator.makeBar()
        context.coordinator.applyHighlighting()
        context.coordinator.updateLineNumbers()
        context.coordinator.refresh()
        context.coordinator.lastFindRequest = findRequest
        if lineRequest > 0 {
            DispatchQueue.main.async { context.coordinator.jumpToLine() }
        }
        context.coordinator.lastLineRequest = lineRequest
        return tv
    }

    func updateUIView(_ view: EditorTextView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.tv else { return }
        if tv.text != text || tv.font?.pointSize != fontSize {
            tv.text = text
            context.coordinator.applyHighlighting()
            context.coordinator.updateLineNumbers()
            context.coordinator.refresh()
        }
        if context.coordinator.lastFindRequest != findRequest {
            context.coordinator.lastFindRequest = findRequest
            tv.findInteraction?.presentFindNavigator(showingReplace: true)
        }
        if context.coordinator.lastLineRequest != lineRequest {
            context.coordinator.lastLineRequest = lineRequest
            context.coordinator.jumpToLine()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        // The viewport fills the available area; the document scrolls inside it.
        return CGSize(width: width, height: height)
    }

    struct Token {
        let prefix: String
        let range: NSRange
        let owner: String?
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        weak var tv: EditorTextView?
        weak var gutter: LineNumberGutter?
        private let scroll = UIScrollView()
        private let stack = UIStackView()
        var lastFindRequest = 0
        var lastLineRequest = 0

        init(_ parent: CodeEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            applyHighlighting()
            updateLineNumbers()
            refresh()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refresh()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard parent.autoIndent, replacement == "\n", textView.markedTextRange == nil else { return true }
            let source = (textView.text ?? "") as NSString
            guard range.location <= source.length else { return true }
            let preceding = source.substring(to: range.location)
            let line = preceding.components(separatedBy: "\n").last ?? ""
            let indent = PythonIndentation.continuation(for: line)
            guard !indent.isEmpty, let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let selection = textView.textRange(from: start, to: end) else { return true }
            textView.replace(selection, withText: "\n" + indent)
            textViewDidChange(textView)
            return false
        }

        func jumpToLine() {
            guard let tv = tv else { return }
            gutter?.updateLines()
            let starts = tv.gutter.lineStarts
            let index = min(max(parent.targetLine - 1, 0), starts.count - 1)
            let location = starts[index]
            let source = (tv.text ?? "") as NSString
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            tv.selectedRange = range
            tv.layoutManager.ensureLayout(for: tv.textContainer)
            tv.scrollRangeToVisible(range)
            UIAccessibility.post(notification: .announcement, argument: "Line \(index + 1)")
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tv = tv, scrollView === tv else { return }
            gutter?.setNeedsDisplay()
        }

        // MARK: Syntax highlighting and line numbers

        func updateLineNumbers() {
            guard let gutter = gutter else { return }
            gutter.updateLines()
            // Leave enough room when source line numbers reach four digits.
            let digits = String(gutter.lineStarts.count).count
            let width = max(34, CGFloat(digits) * parent.fontSize * 0.65 + 12)
            if tv?.gutterWidth != width { tv?.gutterWidth = width }
        }

        func applyHighlighting() {
            guard let tv = tv else { return }
            let source = tv.text ?? ""
            let ns = source as NSString
            let full = NSRange(location: 0, length: ns.length)
            let selection = tv.selectedRange
            let offset = tv.contentOffset
            let font = UIFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            let storage = tv.textStorage

            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: full)

            func paint(_ pattern: String, _ color: UIColor, options: NSRegularExpression.Options = []) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
                for match in regex.matches(in: source, range: full) {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }

            // Apply code colors first; lexical strings/comments take precedence.
            paint("\\b(False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|try|while|with|yield)\\b", .systemPurple)
            paint("\\b[0-9]+(?:\\.[0-9]+)?\\b", .systemOrange)
            paint("\\b(print|input|len|range|int|float|str|bool|list|dict|set|tuple|sum|min|max|round|abs|enumerate|zip|open|super|type|isinstance)\\b(?=\\s*\\()", .systemBlue)
            // One combined scan keeps # inside strings and quotes inside comments
            // from being mistaken for separate tokens. Include multiline strings.
            let literals = #"(?:[rRuUbBfF]{0,2})?(?:\"\"\"[\s\S]*?(?:\"\"\"|\z)|\'\'\'[\s\S]*?(?:\'\'\'|\z)|\"(?:\\.|[^\"\\\r\n])*(?:\"|$)|'(?:\\.|[^'\\\r\n])*(?:'|$))|#[^\r\n]*"#
            if let regex = try? NSRegularExpression(pattern: literals, options: [.anchorsMatchLines]) {
                for match in regex.matches(in: source, range: full) {
                    let token = ns.substring(with: match.range)
                    let color = token.hasPrefix("#") ? UIColor.systemGreen : UIColor.systemRed
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
            storage.endEditing()
            tv.selectedRange = NSRange(location: min(selection.location, ns.length), length: min(selection.length, max(0, ns.length - selection.location)))
            tv.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
            tv.setContentOffset(offset, animated: false)
        }

        // MARK: Suggestion bar

        private func pill(_ title: String) -> UIButton.Configuration {
            var c = UIButton.Configuration.tinted()
            c.title = title
            c.cornerStyle = .capsule
            c.baseForegroundColor = .label
            c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
                return out
            }
            return c
        }

        func makeBar() -> UIView {
            let bar = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.autoresizingMask = .flexibleWidth
            bar.backgroundColor = .secondarySystemBackground

            let tab = UIButton(configuration: pill("⇥"), primaryAction: UIAction { [weak self] _ in
                self?.tv?.insertText("    ")
            })
            let done = UIButton(configuration: pill("Done"), primaryAction: UIAction { [weak self] _ in
                self?.tv?.resignFirstResponder()
            })
            let undo = UIButton(configuration: pill("↶"), primaryAction: UIAction { [weak self] _ in
                self?.tv?.undoManager?.undo()
            })
            undo.accessibilityLabel = "Undo"
            let redo = UIButton(configuration: pill("↷"), primaryAction: UIAction { [weak self] _ in
                self?.tv?.undoManager?.redo()
            })
            redo.accessibilityLabel = "Redo"
            tab.accessibilityLabel = "Indent four spaces"
            for b in [tab, done] {
                b.setContentHuggingPriority(.required, for: .horizontal)
                b.setContentCompressionResistancePriority(.required, for: .horizontal)
            }

            stack.axis = .horizontal
            stack.spacing = 6
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.showsHorizontalScrollIndicator = false
            scroll.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            ])
            scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let row = UIStackView(arrangedSubviews: [undo, redo, tab, scroll, done])
            row.axis = .horizontal
            row.spacing = 6
            row.alignment = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
                row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
                row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
                row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
            ])
            return bar
        }

        func refresh() {
            guard let tv = tv else { return }
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

            var words: [String] = []
            if let tok = token(in: tv) { words = suggestions(for: tok, text: tv.text) }
            let showingWords = !words.isEmpty
            for item in (showingWords ? words : Vocab.symbols) {
                let b = UIButton(configuration: pill(item), primaryAction: UIAction { [weak self] _ in
                    if showingWords { self?.accept(item) } else { self?.tv?.insertText(item) }
                })
                stack.addArrangedSubview(b)
            }
            scroll.setContentOffset(.zero, animated: false)
        }

        private func accept(_ word: String) {
            guard let tv = tv, let tok = token(in: tv) else { return }
            tv.selectedRange = tok.range
            tv.insertText(word)
        }

        // MARK: Finding what is being typed

        private func isIdent(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }

        private func token(in tv: UITextView) -> Token? {
            let ns = tv.text as NSString
            let sel = tv.selectedRange
            guard sel.length == 0, sel.location <= ns.length else { return nil }
            let loc = sel.location
            var start = loc
            while start > 0, isIdent(ns.character(at: start - 1)) { start -= 1 }
            let range = NSRange(location: start, length: loc - start)
            var owner: String? = nil
            if start > 0, ns.character(at: start - 1) == 46 {
                var o = start - 1
                while o > 0, isIdent(ns.character(at: o - 1)) { o -= 1 }
                owner = ns.substring(with: NSRange(location: o, length: start - 1 - o))
            }
            return Token(prefix: ns.substring(with: range), range: range, owner: owner)
        }

        private func documentWords(_ text: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]{2,}") else { return [] }
            let ns = text as NSString
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range)
            }
        }

        private func definedWords(_ text: String) -> [String] {
            let patterns = [
                #"(?m)\b(?:async\s+def|def|class)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
                #"(?m)^\s*(?:from\s+[\w.]+\s+import\s+|import\s+)([A-Za-z_][A-Za-z0-9_]*)"#,
                #"(?m)\b([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)"#
            ]
            let ns = text as NSString
            var found: [String] = []
            for pattern in patterns {
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                        found.append(ns.substring(with: match.range(at: 1)))
                    }
                }
            }
            return found
        }

        private func suggestions(for tok: Token, text: String) -> [String] {
            let pool: [String]
            if let owner = tok.owner {
                if let known = Vocab.members[owner] {
                    pool = known
                } else {
                    // Unknown objects can still offer common Python methods and names in this file.
                    pool = Vocab.generic + documentWords(text)
                }
            } else {
                if tok.prefix.isEmpty { return [] }
                pool = Vocab.globals + documentWords(text)
            }
            let lower = tok.prefix.lowercased()
            let defined = definedWords(text)
            var seen = Set<String>()
            var out: [String] = []
            for w in defined + pool where w != tok.prefix && w.lowercased().hasPrefix(lower) {
                if seen.insert(w).inserted { out.append(w) }
            }
            let definedSet = Set(defined)
            out.sort {
                let lhsDefined = definedSet.contains($0), rhsDefined = definedSet.contains($1)
                if lhsDefined != rhsDefined { return lhsDefined }
                return $0.count != $1.count ? $0.count < $1.count : $0 < $1
            }
            return Array(out.prefix(tok.prefix.isEmpty ? 30 : 14))
        }
    }
}


