import XCTest
#if canImport(PyPhoneAgentProtocol)
@testable import PyPhoneAgentProtocol
#endif

final class AgentProtocolTests: XCTestCase {
    func testValidatedProtocol() throws {
        XCTAssertEqual(try AgentAction.parse(#"{"tool":"read_file","arguments":{}}"#).tool, "read_file")
        XCTAssertThrowsError(try AgentAction.parse(#"{"tool":"read_file","arguments":{"path":"../secret"}}"#))
        XCTAssertThrowsError(try AgentAction.parse(#"{"tool":"delete_file","arguments":{}}"#))
        XCTAssertThrowsError(try AgentAction.parse("not JSON"))
        XCTAssertThrowsError(try AgentAction.parse(#"{"tool":"edit_file","arguments":{"content":12}}"#))
        XCTAssertThrowsError(try AgentAction.parse(#"{"tool":"report","arguments":{"text":"done"},"extra":true}"#))
    }

}

extension AgentProtocolTests {
    func testFencedJSONAndAmbiguousResponses() throws {
        let action = #"{"tool":"read_file","arguments":{}}"#
        XCTAssertEqual(try AgentAction.parse(" \n```json\n" + action + "\n```\n").tool, "read_file")
        XCTAssertEqual(try AgentAction.parse("```\n" + action + "\n```").tool, "read_file")
        for invalid in ["Here is JSON: " + action, action + action,
                        "```json\n" + action + "\n```\nExtra prose", "[]", "null", "{", ""] {
            XCTAssertThrowsError(try AgentAction.parse(invalid)) { XCTAssertTrue($0 is AgentProtocolError) }
        }
    }

    func testSchemaDiagnosticsDoNotEchoUntrustedData() {
        let cases: [(String, String)] = [
            (#"{"arguments":{}}"#, "Missing required field: tool"),
            (#"{"tool":12,"arguments":{}}"#, "Field tool must be a string"),
            (#"{"tool":"read_file"}"#, "Missing required field: arguments"),
            (#"{"tool":"read_file","arguments":null}"#, "Field arguments must be an object"),
            (#"{"tool":"read_file","arguments":[]}"#, "Field arguments must be an object"),
            (#"{"tool":"edit_file","arguments":{}}"#, "Missing required arguments for edit_file: content"),
            (#"{"tool":"edit_file","arguments":{"content":true}}"#, "Argument edit_file.content must be a string"),
            (#"{"tool":"SECRET","arguments":{}}"#, "Unsupported tool"),
            (#"{"tool":"read_file","arguments":{"SECRET":"SECRET"}}"#, "Unexpected arguments")
        ]
        for (input, expected) in cases {
            XCTAssertThrowsError(try AgentAction.parse(input)) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            }
        }
    }

    func testProviderEnvelopeDiagnostics() throws {
        let valid = #"{"choices":[{"finish_reason":"stop","message":{"content":"hello"}}]}"#
        XCTAssertEqual(try AgentProvider.parseResponse(Data(valid.utf8)), "hello")
        for invalid in ["not JSON", "{}", #"{"choices":[]}"#,
                        #"{"choices":[{"finish_reason":"length","message":{"content":"SECRET"}}]}"#,
                        #"{"choices":[{"finish_reason":"stop","message":{"content":null}}]}"#] {
            XCTAssertThrowsError(try AgentProvider.parseResponse(Data(invalid.utf8))) { error in
                XCTAssertTrue(error is AgentProtocolError)
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            }
        }
    }

    func testProviderAcceptsTextContentParts() throws {
        let action = #"{"tool":"report","arguments":{"text":"OK"}}"#
        let pieces = [String(action.prefix(16)), String(action.dropFirst(16))]
        let envelope: [String: Any] = [
            "choices": [[
                "finish_reason": "stop",
                "message": ["content": pieces.map { ["type": "text", "text": $0] }]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let content = try AgentProvider.parseResponse(data)
        XCTAssertEqual(try AgentAction.parse(content).tool, "report")
    }

    func testProviderRejectsNativeToolsAndEmptyContentWithoutEcho() {
        let cases = [
            (#"{"choices":[{"finish_reason":"tool_calls","message":{"content":null,"tool_calls":[{"secret":"SECRET"}]}}]}"#, "native tool calls"),
            (#"{"choices":[{"finish_reason":"stop","message":{"content":null,"tool_calls":[{"secret":"SECRET"}]}}]}"#, "native tool calls"),
            (#"{"choices":[{"finish_reason":"stop","message":{"content":""}}]}"#, "empty"),
            (#"{"choices":[{"finish_reason":"length","message":{"content":"SECRET"}}]}"#, "truncated")
        ]
        for (input, expected) in cases {
            XCTAssertThrowsError(try AgentProvider.parseResponse(Data(input.utf8))) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            }
        }
    }

    @MainActor func testRecoveryValidatesBeforeReturningAction() async throws {
        var messages = [["role": "user", "content": "Read the script"]]
        var retries = 0
        var calls = 0
        var diagnostics: [String] = []
        let action = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries, request: { history in
            calls += 1
            if calls == 1 { return #"{"tool":"SECRET","arguments":{}}"# }
            XCTAssertTrue(history.last!["content"]!.contains(AgentAction.protocolInstructions))
            XCTAssertFalse(history.description.contains("SECRET"))
            return #"{"tool":"read_file","arguments":{}}"#
        }, diagnostic: { diagnostics.append($0) })
        XCTAssertEqual(action.tool, "read_file")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(diagnostics.count, 2)
    }

    @MainActor func testRecoveryExhaustionAndTaskWideBudget() async {
        var messages: [[String: String]] = []
        var retries = 0
        var calls = 0
        do {
            _ = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries, request: { _ in
                calls += 1; return "invalid JSON"
            }, diagnostic: { _ in })
            XCTFail("Invalid action returned")
        } catch { XCTAssertTrue(error.localizedDescription.contains("exhausted")) }
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(retries, 3)
        do {
            _ = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries, request: { _ in
                calls += 1; return "invalid JSON"
            }, diagnostic: { _ in })
            XCTFail("Budget reset unexpectedly")
        } catch { XCTAssertTrue(error.localizedDescription.contains("exhausted")) }
        XCTAssertEqual(calls, 5)
    }

    @MainActor func testCancellationIsNotRetried() async {
        var messages: [[String: String]] = []
        var retries = 0
        do {
            _ = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries, request: { _ in
                throw CancellationError()
            }, diagnostic: { _ in XCTFail("Cancellation logged as protocol failure") })
            XCTFail("Cancellation swallowed")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(retries, 0)
    }
}


extension AgentProtocolTests {
    func testInitialScriptContextIsBoundedAndMarkedUntrusted() {
        XCTAssertEqual(AgentContext.selectedScript("print('hello')"),
                       "Untrusted selected script:\nprint('hello')")
        let context = AgentContext.selectedScript(String(repeating: "x", count: 100_000) + "OMITTED")
        XCTAssertTrue(context.contains("search_code"))
        XCTAssertFalse(context.contains("OMITTED"))
        XCTAssertTrue(context.hasSuffix(String(repeating: "x", count: 100_000)))
    }

    @MainActor func testTerminalProviderResponsesDoNotSpendCorrectionRequests() async {
        for reason in ["content_filter"] {
            var messages: [[String: String]] = []
            var retries = 0
            var calls = 0
            do {
                _ = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries,
                    request: { _ in
                        calls += 1
                        let data = try JSONSerialization.data(withJSONObject: [
                            "choices": [["finish_reason": reason, "message": ["content": "SECRET"]]]
                        ])
                        return try AgentProvider.parseResponse(data)
                    }, diagnostic: { XCTAssertFalse($0.contains("SECRET")) })
                XCTFail("Terminal response accepted")
            } catch {
                XCTAssertEqual((error as? AgentProtocolError)?.retryable, false)
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(retries, 0)
            XCTAssertTrue(messages.isEmpty)
        }
    }

    @MainActor func testConnectionProbeDoesNotRetryInvalidJSON() async {
        var messages: [[String: String]] = []
        var retries = 0
        var calls = 0
        do {
            _ = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries,
                maxRetries: 0, request: { _ in
                    calls += 1
                    return "invalid"
                }, diagnostic: { _ in })
            XCTFail("Invalid connection probe accepted")
        } catch { XCTAssertTrue(error is AgentProtocolError) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(retries, 0)
    }

    @MainActor func testCancelledTaskNeverContactsProvider() async {
        let task = Task {
            var messages: [[String: String]] = []
            var retries = 0
            do {
                _ = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries,
                    request: { _ in
                        XCTFail("Cancelled task contacted provider")
                        return ""
                    }, diagnostic: { _ in })
                XCTFail("Cancelled task succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        task.cancel()
        await task.value
    }
}


extension AgentProtocolTests {
    private func actionJSON(_ tool: String, _ arguments: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments])
        return String(decoding: data, as: UTF8.self)
    }

    func testOutputBudgetUsesExactlyOneProviderSpecificParameter() throws {
        for (provider, model, key) in [
            ("OpenRouter", "baidu/ernie-5.5-flash-preview:free", "max_tokens"),
            ("OpenRouter", "cohere/north-mini-code:free", "max_tokens"),
            ("OpenAI", "o3", "max_completion_tokens")
        ] {
            let messages = [["role": "user", "content": "Fix a quote: \" and newline\n"]]
            let data = try AgentProvider(provider: provider, model: model, paid: true).requestBody(messages)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body[key] as? Int, 16_384)
            XCTAssertNil(body[key == "max_tokens" ? "max_completion_tokens" : "max_tokens"])
            XCTAssertEqual(body["messages"] as? [[String: String]], messages)
            XCTAssertEqual(body["model"] as? String, model)
            XCTAssertNil(body["tools"]) // The existing protocol is JSON text, not native tools.
        }
    }

    func testSmallPatchPreservesLargeScriptAndEscapedUnicode() throws {
        let prefix = String(repeating: "# unchanged\n", count: 10_000)
        let old = "print(\"hello 🐦\")\n"
        let new = "print(\"hello \\\"bird\\\" 🐦\")\nprint('done')\n"
        let action = try AgentAction.parse(actionJSON("patch_file", ["old_text": old, "new_text": new]))
        XCTAssertEqual(try action.editedScript(prefix + old), prefix + new)
        let deletion = try AgentAction.parse(actionJSON("patch_file", ["old_text": old, "new_text": ""]))
        XCTAssertEqual(try deletion.editedScript(prefix + old), prefix)
        let replacement = try AgentAction.parse(actionJSON("edit_file", ["content": new]))
        XCTAssertEqual(try replacement.editedScript(old), new)
    }

    func testPatchRejectsMissingEmptyAndAmbiguousAnchors() throws {
        for (before, old) in [("abc", ""), ("abc", "SECRET"), ("aa", "a"), ("aaa", "aa")] {
            let action = try AgentAction.parse(actionJSON("patch_file", ["old_text": old, "new_text": "x"]))
            XCTAssertThrowsError(try action.editedScript(before)) {
                XCTAssertTrue($0 is AgentProtocolError)
                XCTAssertFalse($0.localizedDescription.contains("SECRET"))
            }
        }
        for arguments in [["old_text": "a"], ["old_text": "a", "new_text": "b", "path": "x"]] {
            XCTAssertThrowsError(try AgentAction.parse(actionJSON("patch_file", arguments)))
        }
    }

    func testSerializedEditLimitIncludesEscapingAndUTF8() throws {
        for value in [String(repeating: "x", count: 12_000),
                      String(repeating: "\"\n", count: 4_000),
                      String(repeating: "🐦", count: 3_000)] {
            for (tool, arguments) in [("edit_file", ["content": value]),
                                      ("patch_file", ["old_text": "anchor", "new_text": value])] {
                let raw = try actionJSON(tool, arguments)
                XCTAssertGreaterThan(raw.utf8.count, AgentAction.maxEditBytes)
                XCTAssertThrowsError(try AgentAction.parse(raw)) {
                    XCTAssertTrue($0.localizedDescription.contains("smaller patch_file"))
                }
            }
        }
        // Test the exact boundary including the JSON envelope, not just the code.
        let empty = try actionJSON("edit_file", ["content": ""])
        let fitting = try actionJSON("edit_file", ["content": String(repeating: "x", count: 12_000 - empty.utf8.count)])
        XCTAssertEqual(fitting.utf8.count, 12_000)
        XCTAssertEqual(try AgentAction.parse(fitting).tool, "edit_file")
        XCTAssertThrowsError(try AgentAction.parse(actionJSON("edit_file", ["content": String(repeating: "x", count: 12_001 - empty.utf8.count)])))
    }

    @MainActor func testTruncationRetriesSmallerActionWithoutExecutingPartialJSON() async throws {
        // Even valid-looking JSON must not execute when the provider reports length.
        for partial in ["{\"tool\":\"edit_file\",\"arguments\":{\"content\":\"SECRET",
                        try actionJSON("edit_file", ["content": "SECRET"]), ""] {
            var messages: [[String: String]] = []
            var retries = 0
            var calls = 0
            var validated: [String] = []
            let result = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries,
                request: { history in
                    calls += 1
                    if calls == 1 {
                        let envelope: [String: Any] = ["choices": [["finish_reason": "length", "message": ["content": partial]]]]
                        return try AgentProvider.parseResponse(JSONSerialization.data(withJSONObject: envelope))
                    }
                    XCTAssertTrue(history.last!["content"]!.contains("smaller patch_file"))
                    XCTAssertFalse(history.description.contains("SECRET"))
                    return try self.actionJSON("patch_file", ["old_text": "a", "new_text": "b"])
                }, diagnostic: { XCTAssertFalse($0.contains("SECRET")) }, validate: {
                    validated.append($0.tool)
                    _ = try $0.editedScript("a")
                })
            XCTAssertEqual(result.tool, "patch_file")
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(retries, 1)
            XCTAssertEqual(validated, ["patch_file"])
        }
    }

    @MainActor func testRepeatedTruncationStopsAtTaskWideRetryLimit() async {
        var messages: [[String: String]] = []
        var retries = 0
        var calls = 0
        do {
            _ = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries, request: { _ in
                calls += 1
                return try AgentProvider.parseResponse(Data(#"{"choices":[{"finish_reason":"length","message":{"content":"SECRET"}}]}"#.utf8))
            }, diagnostic: { _ in }, validate: { _ in XCTFail("Truncated response reached execution") })
            XCTFail("Repeated truncation accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("exhausted")) }
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(retries, 3)
        XCTAssertFalse(messages.description.contains("SECRET"))
    }

    @MainActor func testInvalidPatchCanBeCorrectedBeforeApproval() async throws {
        var messages: [[String: String]] = []
        var retries = 0
        var calls = 0
        let result = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries, request: { _ in
            calls += 1
            return try self.actionJSON("patch_file", ["old_text": calls == 1 ? "SECRET" : "a", "new_text": "b"])
        }, diagnostic: { _ in }, validate: { _ = try $0.editedScript("a") })
        XCTAssertEqual(try result.editedScript("a"), "b")
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(messages.description.contains("SECRET"))
    }

    func testRejectsEmptyPartsAndMixedNativeCalls() throws {
        let messages: [[String: Any]] = [
            ["content": [["type": "text", "text": " \n"]]],
            ["content": "valid-looking text", "tool_calls": [["id": "SECRET"]]],
            ["content": "valid-looking text", "function_call": ["name": "SECRET"]]
        ]
        for message in messages {
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": message]]])
            XCTAssertThrowsError(try AgentProvider.parseResponse(data)) {
                XCTAssertFalse($0.localizedDescription.contains("SECRET"))
            }
        }
    }
}


extension AgentProtocolTests {
    func testNullNativeToolFieldsStillAllowText() throws {
        let data = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"hello","tool_calls":null,"function_call":null}}]}"#.utf8)
        XCTAssertEqual(try AgentProvider.parseResponse(data), "hello")
        let emptyCalls = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"hello","tool_calls":[]}}]}"#.utf8)
        XCTAssertEqual(try AgentProvider.parseResponse(emptyCalls), "hello")
    }

    @MainActor func testOversizedEditIsRetriedAsPatch() async throws {
        var messages: [[String: String]] = []
        var retries = 0
        var calls = 0
        let result = try await AgentProtocolRecovery.next(messages: &messages, retries: &retries, request: { history in
            calls += 1
            if calls == 1 {
                return try self.actionJSON("edit_file", ["content": String(repeating: "SECRET", count: 3_000)])
            }
            XCTAssertTrue(history.last!["content"]!.contains("smaller patch_file"))
            XCTAssertFalse(history.description.contains("SECRET"))
            return try self.actionJSON("patch_file", ["old_text": "a", "new_text": "b"])
        }, diagnostic: { _ in }, validate: { _ = try $0.editedScript("a") })
        XCTAssertEqual(result.tool, "patch_file")
        XCTAssertEqual(retries, 1)
    }
}
