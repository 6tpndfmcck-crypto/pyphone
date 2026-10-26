import Foundation

enum PythonIndentation {
    /// Continue leading whitespace; add one level after a block colon. Ignore
    /// colons in a single-line string or comment. This is an editing aid, not a parser.
    static func continuation(for line: String) -> String {
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        var quote: Character?
        var escaped = false
        var code = ""
        for character in line {
            if escaped { escaped = false; continue }
            if let delimiter = quote {
                if character == "\\" { escaped = true }
                else if character == delimiter { quote = nil }
                continue
            }
            if character == "#" { break }
            if character == "\"" || character == "'" { quote = character; code += "s" }
            else { code.append(character) }
        }
        let opensBlock = quote == nil && code.trimmingCharacters(in: .whitespaces).hasSuffix(":")
        return leading + (opensBlock ? "    " : "")
    }
}
