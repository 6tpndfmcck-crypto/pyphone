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

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground

        let gutter = UILabel()
        gutter.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        gutter.textColor = .tertiaryLabel
        gutter.textAlignment = .right
        gutter.numberOfLines = 0
        gutter.backgroundColor = .secondarySystemBackground
        gutter.translatesAutoresizingMaskIntoConstraints = false

        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.textColor = .label
        tv.backgroundColor = .systemBackground
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.spellCheckingType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.text = text
        tv.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(gutter)
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 34),
            tv.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.tv = tv
        context.coordinator.gutter = gutter
        tv.inputAccessoryView = context.coordinator.makeBar()
        context.coordinator.updateLineNumbers()
        context.coordinator.refresh()
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.tv else { return }
        if tv.text != text {
            tv.text = text
            context.coordinator.applyHighlighting()
            context.coordinator.updateLineNumbers()
            context.coordinator.refresh()
        }
    }

    struct Token {
        let prefix: String
        let range: NSRange
        let owner: String?
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        weak var tv: UITextView?
        weak var gutter: UILabel?
        private let scroll = UIScrollView()
        private let stack = UIStackView()

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

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tv = tv, scrollView === tv else { return }
            gutter?.transform = CGAffineTransform(translationX: 0, y: -tv.contentOffset.y)
        }

        // MARK: Syntax highlighting and line numbers

        func updateLineNumbers() {
            guard let tv = tv, let gutter = gutter else { return }
            let count = max(1, tv.text.components(separatedBy: "\n").count)
            gutter.text = (1...count).map(String.init).joined(separator: "\n")
            gutter.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 7)
            gutter.transform = CGAffineTransform(translationX: 0, y: -tv.contentOffset.y)
        }

        func applyHighlighting() {
            guard let tv = tv else { return }
            let source = tv.text ?? ""
            let ns = source as NSString
            let full = NSRange(location: 0, length: ns.length)
            let selection = tv.selectedRange
            let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let storage = tv.textStorage

            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: full)

            func paint(_ pattern: String, _ color: UIColor, options: NSRegularExpression.Options = []) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
                for match in regex.matches(in: source, range: full) {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }

            // Comments and quoted strings are highlighted before keywords and numbers.
            paint("#[^\\n]*", .systemGreen)
            paint("\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'", .systemRed)
            paint("\\b(False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|try|while|with|yield)\\b", .systemPurple)
            paint("\\b[0-9]+(?:\\.[0-9]+)?\\b", .systemOrange)
            paint("\\b(print|input|len|range|int|float|str|bool|list|dict|set|tuple|sum|min|max|round|abs|enumerate|zip|open|super|type|isinstance)\\b(?=\\s*\\()", .systemBlue)
            storage.endEditing()
            tv.selectedRange = NSRange(location: min(selection.location, ns.length), length: min(selection.length, max(0, ns.length - selection.location)))
            tv.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
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

            let row = UIStackView(arrangedSubviews: [tab, scroll, done])
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
