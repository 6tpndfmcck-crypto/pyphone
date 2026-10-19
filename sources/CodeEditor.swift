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
        + words("math random time json os sys datetime re string collections itertools functools threading statistics decimal fractions copy textwrap base64 hashlib uuid pathlib typing dataclasses enum csv sqlite3 urllib heapq bisect")
        + words("ui label entry button clear")

    static let generic: [String] = words("append extend insert remove pop sort reverse index count join split strip lstrip rstrip replace upper lower title capitalize format startswith endswith find keys values items get update add copy clear isdigit isalpha")

    static let members: [String: [String]] = [
        "math": words("pi e tau inf nan sqrt pow exp log log2 log10 sin cos tan asin acos atan atan2 sinh cosh tanh floor ceil fabs factorial gcd lcm hypot degrees radians isclose isnan isinf trunc comb perm prod dist fsum"),
        "random": words("random randint randrange choice choices shuffle sample uniform gauss seed betavariate expovariate"),
        "time": words("time sleep monotonic perf_counter process_time strftime localtime gmtime ctime"),
        "json": words("dumps loads dump load"),
        "os": words("getcwd listdir path environ mkdir remove rename getenv sep walk"),
        "sys": words("argv path version platform exit stdout stderr modules maxsize"),
        "datetime": words("datetime date time timedelta timezone"),
        "string": words("ascii_letters ascii_lowercase ascii_uppercase digits punctuation whitespace"),
        "ui": words("label entry button clear"),
    ]

    static let symbols: [String] = ["(", ")", ":", "\"", "'", "=", "[", "]", "{", "}", "_", "#", ".", ",", "+", "-", "*", "/", "%", "<", ">"]
}

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.textColor = .label
        tv.backgroundColor = .clear
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
        context.coordinator.tv = tv
        tv.inputAccessoryView = context.coordinator.makeBar()
        context.coordinator.refresh()
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text {
            tv.text = text
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
        private let scroll = UIScrollView()
        private let stack = UIStackView()

        init(_ parent: CodeEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            refresh()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refresh()
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

        private func suggestions(for tok: Token, text: String) -> [String] {
            let pool: [String]
            if let owner = tok.owner {
                if let known = Vocab.members[owner] {
                    pool = known
                } else if tok.prefix.isEmpty {
                    return []
                } else {
                    pool = Vocab.generic + documentWords(text)
                }
            } else {
                if tok.prefix.isEmpty { return [] }
                pool = Vocab.globals + documentWords(text)
            }
            let lower = tok.prefix.lowercased()
            var seen = Set<String>()
            var out: [String] = []
            for w in pool where w != tok.prefix && w.lowercased().hasPrefix(lower) {
                if seen.insert(w).inserted { out.append(w) }
            }
            out.sort { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
            return Array(out.prefix(tok.prefix.isEmpty ? 30 : 14))
        }
    }
}
