import Foundation

enum ConsoleBuffer {
    static func appending(_ extra: String, to existing: String) -> String {
        let combined = existing + extra
        let source = combined as NSString
        guard source.length > 200_000 else { return combined }
        var start = source.length - 150_000
        // Never cut a UTF-16 surrogate pair. Counting UTF-16 also bounds strings
        // consisting of a single enormous combining-character sequence.
        let unit = source.character(at: start)
        if unit >= 0xDC00 && unit <= 0xDFFF { start += 1 }
        return "[Older output trimmed]\n" + source.substring(from: start)
    }
}
