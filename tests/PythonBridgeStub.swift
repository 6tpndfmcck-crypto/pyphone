import Foundation

// UI/model tests compile all Swift screens without the device-only Python binary.
// The actual interpreter bridge is exercised by the IPA build and Python tests.
final class PythonBridge {
    static func start() -> String? { nil }
    static func call(_ function: String, arg: String) -> String {
        switch function {
        case "check_runtime": return "Python ready · UI test runtime"
        case "get_state": return #"{"widgets":[],"running":false,"prompt":null,"prompt_id":0,"tid":0,"seq":0,"error_line":null}"#
        case "list_packages": return "[]"
        default: return ""
        }
    }
    static func stopThread(_ tid: UInt) {}
}
