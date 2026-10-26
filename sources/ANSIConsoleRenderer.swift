import UIKit

enum ANSIConsoleRenderer {
    // SGR colors from Colorama and Python error reporting. Unsupported CSI
    // commands are consumed rather than displayed as escape-code clutter.
    static func render(_ source: String, fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let ns = source as NSString
        let regex = try! NSRegularExpression(pattern: "\u{001B}\\[([0-9;]*)([@-~])")
        var color = UIColor.label
        var background: UIColor?
        var bold = false
        var position = 0
        let colors: [UIColor] = [.label, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .secondaryLabel]
        func append(_ range: NSRange) {
            guard range.length > 0 else { return }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: bold ? .bold : .regular),
                .foregroundColor: color
            ]
            if let background = background { attributes[.backgroundColor] = background }
            result.append(NSAttributedString(string: ns.substring(with: range), attributes: attributes))
        }
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            append(NSRange(location: position, length: match.range.location - position))
            if ns.substring(with: match.range(at: 2)) == "m" {
                let values = ns.substring(with: match.range(at: 1)).components(separatedBy: ";").map { Int($0) ?? 0 }
                for value in values {
                    switch value {
                    case 0: color = .label; background = nil; bold = false
                    case 1: bold = true
                    case 22: bold = false
                    case 30...37: color = colors[value - 30]
                    case 90...97: color = colors[value - 90]
                    case 39: color = .label
                    case 40...47: background = colors[value - 40]
                    case 100...107: background = colors[value - 100]
                    case 49: background = nil
                    default: break
                    }
                }
            }
            position = NSMaxRange(match.range)
        }
        // A poll can split an ANSI sequence. Hold its suffix until the next
        // complete output snapshot instead of flashing a partial escape code.
        let remaining = ns.substring(from: position)
        let tail = remaining as NSString
        let partial = tail.range(of: "\u{001B}", options: .backwards)
        let count = partial.location == NSNotFound ? tail.length : partial.location
        append(NSRange(location: position, length: count))
        return result
    }
}
