import Foundation

// UI/model tests compile all Swift screens without the device-only Python binary.
// The actual interpreter bridge is exercised by the IPA build and Python tests.
final class PythonBridge {
    private static let lock = NSLock()
    private static var promptState: String?
    static func setPromptState(_ state: String?) {
        lock.lock()
        promptState = state
        lock.unlock()
    }
    static func start() -> String? { nil }
    static func call(_ function: String, arg: String) -> String {
        switch function {
        case "check_runtime": return "Python ready · UI test runtime"
        case "get_state":
            lock.lock()
            defer { lock.unlock() }
            return promptState ?? #"{"widgets":[],"running":false,"prompt":null,"prompt_id":0,"tid":0,"seq":0,"error_line":null}"#
        case "list_packages": return "[]"
        default: return ""
        }
    }
    static func stopThread(_ tid: UInt) {}
}
