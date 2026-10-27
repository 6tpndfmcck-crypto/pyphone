import Foundation

// UI/model tests compile all Swift screens without the device-only Python binary.
// The actual interpreter bridge is exercised by the IPA build and Python tests.
final class PythonBridge {
    private static let lock = NSLock()
    private static var promptState: String?
    private static var pendingOutput = ""
    private static var stateArguments: [String] = []
    private static var pendingStateArgument: String?
    static func setPromptState(_ state: String?) {
        lock.lock()
        promptState = state
        lock.unlock()
    }
    static func setState(_ state: String?, output: String = "") {
        lock.lock()
        promptState = state
        pendingOutput = output
        lock.unlock()
    }
    static func getStateArguments() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return stateArguments
    }
    static func reset() {
        lock.lock()
        promptState = nil
        pendingOutput = ""
        stateArguments.removeAll()
        pendingStateArgument = nil
        lock.unlock()
    }
    static func start() -> String? { nil }
    static func call(_ function: String, arg: String) -> String {
        switch function {
        case "check_runtime": return "Python ready · UI test runtime"
        case "get_state":
            lock.lock()
            defer { lock.unlock() }
            pendingStateArgument = arg
            return promptState ?? #"{"widgets":[],"running":false,"prompt":null,"prompt_id":0,"tid":0,"seq":0,"error_line":null}"#
        case "take_output":
            lock.lock()
            defer { lock.unlock() }
            let output = pendingOutput
            pendingOutput = ""
            // Cursor-based test waits must observe a completed state/output
            // read. Recording at get_state would let a previous test's runner
            // drain the next test's output before its queued completion exits.
            if let argument = pendingStateArgument {
                stateArguments.append(argument)
                if stateArguments.count > 1_000 { stateArguments.removeFirst(stateArguments.count - 1_000) }
                pendingStateArgument = nil
            }
            return output
        case "list_packages": return "[]"
        default: return ""
        }
    }
    static func stopThread(_ tid: UInt) {}
}
