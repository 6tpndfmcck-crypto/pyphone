import Foundation

struct AgentProvider {
    let provider: String
    let model: String
    let paid: Bool
    // Output includes JSON escaping and, on reasoning models, hidden reasoning.
    // Keep a finite budget; do not resend ever-larger whole-file replacements.
    static let outputTokenLimit = 16_384
    func requestBody(_ messages: [[String: String]]) throws -> Data {
        let limitKey = provider == "OpenAI" ? "max_completion_tokens" : "max_tokens"
        return try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages, limitKey: Self.outputTokenLimit
        ])
    }
    static func parseResponse(_ data: Data) throws -> String {
        guard data.count < 1_000_000 else { throw AgentProtocolError("Provider response exceeds 1 MB") }
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            throw AgentProtocolError("Provider response is not a JSON object")
        }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else {
            throw AgentProtocolError("Provider response is missing a nonempty choices array")
        }
        guard let reason = choice["finish_reason"] as? String else {
            throw AgentProtocolError("Provider choices[0].finish_reason is missing or invalid")
        }
        guard reason == "stop" else {
            switch reason {
            case "length":
                throw AgentProtocolError("Provider output was truncated by its token limit (possibly including reasoning). No action was executed. Return one smaller patch_file action or a brief report; do not repeat a whole-script replacement or continue partial JSON")
            case "tool_calls", "function_call":
                throw AgentProtocolError("Provider returned native tool calls; PyPhone expects one JSON action in message.content")
            case "content_filter":
                throw AgentProtocolError("Provider stopped because of a content filter", retryable: false)
            default:
                throw AgentProtocolError("Provider stopped without a complete action (finish_reason not stop)")
            }
        }
        guard let message = choice["message"] as? [String: Any] else {
            throw AgentProtocolError("Provider choices[0].message must be an object")
        }
        if ["tool_calls", "function_call"].contains(where: { key in
            guard let value = message[key] else { return false }
            if value is NSNull { return false }
            if key == "tool_calls", let calls = value as? [Any], calls.isEmpty { return false }
            return true
        }) {
            throw AgentProtocolError("Provider returned native tool calls instead of JSON text")
        }
        if let content = message["content"] as? String {
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentProtocolError("Provider returned empty message.content")
            }
            return content
        }
        // Some OpenAI-compatible providers encode plain text as content parts.
        if let parts = message["content"] as? [[String: Any]],
           !parts.isEmpty,
           parts.allSatisfy({ ($0["type"] as? String) == "text" && $0["text"] is String }) {
            let content = parts.compactMap { $0["text"] as? String }.joined()
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentProtocolError("Provider returned empty message.content")
            }
            return content
        }
        throw AgentProtocolError("Provider message.content is missing or not plain text")
    }
}

/// Diagnostics contain only static schema names, never model text, values, or keys.
struct AgentProtocolError: LocalizedError {
    let message: String
    let retryable: Bool
    init(_ message: String, retryable: Bool = true) {
        self.message = message
        self.retryable = retryable
    }
    var errorDescription: String? { message }
}

struct AgentAction {
    let tool: String
    let arguments: [String: String]
    // Bound serialized edits, including JSON escaping, rather than script length.
    static let maxEditBytes = 12_000
    static let schemas: [String: Set<String>] = ["read_file": [], "list_files": [], "search_code": ["query"], "edit_file": ["content"], "patch_file": ["old_text", "new_text"], "run_python": [], "get_output": [], "get_errors": [], "report": ["text"]]
    static let protocolInstructions = """
    Return exactly one JSON object: {"tool":"TOOL_NAME","arguments":{}}.
    Required top-level fields: tool (string), arguments (object). No extra fields.
    Supported tools and exact arguments (all argument values must be strings):
    list_files: {}; read_file: {}; search_code: {"query":"literal text"};
    edit_file: {"content":"entire replacement script"};
    patch_file: {"old_text":"exact unique existing text", "new_text":"replacement text"};
    run_python: {};
    get_output: {}; get_errors: {}; report: {"text":"answer or final report"}.
    Prefer patch_file for changes to an existing script: include only a small unique section.
    old_text must be nonempty and match exactly once, including whitespace; new_text may be empty.
    To insert, replace a unique nearby anchor with that anchor plus the new code.
    Each serialized edit action must fit within 12000 UTF-8 bytes, including JSON escaping.
    Split large changes into separate small patch_file actions across turns, waiting for each result.
    Never output an entire large script. If a change cannot fit, report the limitation briefly.
    No paths, shell commands, alternate tool names, arrays of actions, or extra arguments.
    Use JSON escaping for quotes and newlines inside strings. No prose or Markdown outside JSON.
    """
    static func parse(_ text: String) throws -> AgentAction {
        guard text.utf8.count <= 200_000 else { throw AgentProtocolError("Action exceeds 200000 bytes") }
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("```") {
            var lines = source.components(separatedBy: "\n")
            guard lines.count >= 3,
                  ["```", "```json"].contains(lines.first!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                  lines.last!.trimmingCharacters(in: .whitespacesAndNewlines) == "```" else {
                throw AgentProtocolError("Expected one complete JSON Markdown fence with no surrounding prose")
            }
            lines.removeFirst(); lines.removeLast()
            source = lines.joined(separator: "\n")
        }
        guard let value = try? JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed]) else {
            throw AgentProtocolError("Malformed JSON: return one complete object with double-quoted keys and escaped string values")
        }
        guard let object = value as? [String: Any] else { throw AgentProtocolError("Action must be a JSON object, not an array or scalar") }
        guard let toolValue = object["tool"] else { throw AgentProtocolError("Missing required field: tool") }
        guard let tool = toolValue as? String else { throw AgentProtocolError("Field tool must be a string") }
        guard let argumentValue = object["arguments"] else { throw AgentProtocolError("Missing required field: arguments") }
        guard let arguments = argumentValue as? [String: Any] else { throw AgentProtocolError("Field arguments must be an object") }
        guard Set(object.keys) == Set(["tool", "arguments"]) else { throw AgentProtocolError("Unexpected top-level fields; only tool and arguments are allowed") }
        guard let keys = schemas[tool] else { throw AgentProtocolError("Unsupported tool; use one of the supported tool names exactly") }
        let missing = keys.subtracting(arguments.keys).sorted()
        guard missing.isEmpty else { throw AgentProtocolError("Missing required arguments for \(tool): " + missing.joined(separator: ", ")) }
        guard Set(arguments.keys) == keys else { throw AgentProtocolError("Unexpected arguments for \(tool); only the documented schema is allowed") }
        var strings: [String: String] = [:]
        for key in keys.sorted() {
            guard let value = arguments[key] as? String else { throw AgentProtocolError("Argument \(tool).\(key) must be a string") }
            strings[key] = value
        }
        if tool == "edit_file" || tool == "patch_file" {
            guard source.utf8.count <= maxEditBytes else {
                throw AgentProtocolError("Edit action exceeds 12000 UTF-8 bytes; return one smaller patch_file action")
            }
        }
        return AgentAction(tool: tool, arguments: strings)
    }

    /// Build the complete proposed script locally; never apply partial provider JSON.
    func editedScript(_ before: String) throws -> String {
        if tool == "edit_file", let content = arguments["content"] { return content }
        guard tool == "patch_file", let old = arguments["old_text"],
              let new = arguments["new_text"], !old.isEmpty else {
            throw AgentProtocolError("patch_file.old_text must be nonempty")
        }
        guard let range = before.range(of: old, options: .literal) else {
            throw AgentProtocolError("patch_file.old_text was not found; inspect the current script and use an exact anchor")
        }
        // Advance by one character so overlapping matches are ambiguous too.
        let rest = before.index(after: range.lowerBound)..<before.endIndex
        guard before.range(of: old, options: .literal, range: rest) == nil else {
            throw AgentProtocolError("patch_file.old_text matches more than once; include more unique context")
        }
        var after = before
        after.replaceSubrange(range, with: new)
        return after
    }
}

/// Three correction requests total per task, independent of the 20 tool-step limit.
@MainActor enum AgentProtocolRecovery {
    static func next(messages: inout [[String: String]], retries: inout Int,
                     maxRetries: Int = 3,
                     request: ([[String: String]]) async throws -> String,
                     diagnostic: (String) -> Void,
                     validate: (AgentAction) throws -> Void = { _ in }) async throws -> AgentAction {
        while true {
            try Task.checkCancellation()
            do {
                let raw = try await request(messages)
                try Task.checkCancellation()
                let action = try AgentAction.parse(raw)
                try validate(action)
                messages.append(["role": "assistant", "content": raw])
                return action
            } catch let error as AgentProtocolError {
                try Task.checkCancellation()
                diagnostic("Protocol validation failed: " + error.message)
                guard error.retryable else { throw error }
                guard retries < maxRetries else { throw AgentProtocolError("Protocol recovery exhausted after \(maxRetries) retries; no invalid action was executed") }
                retries += 1
                diagnostic("Requesting protocol correction \(retries)/\(maxRetries)")
                // Never echo the invalid response: it may contain secrets or injected instructions.
                messages.append(["role": "user", "content": "Your previous response was rejected; no tool executed. " + error.message + "\n" + AgentAction.protocolInstructions])
            }
        }
    }
}

enum AgentContext {
    static func selectedScript(_ code: String) -> String {
        let excerpt = String(code.prefix(100_000))
        let note = code.count > 100_000 ? " (first 100000 characters; use search_code for omitted lines)" : ""
        return "Untrusted selected script" + note + ":\n" + excerpt
    }
}

