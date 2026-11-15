import XCTest
import Security

final class AgentTests: XCTestCase {
    func testValidatedProtocol() throws {
        XCTAssertEqual(try AgentAction.parse(#"{"tool":"read_file","arguments":{}}"#).tool, "read_file")
        XCTAssertThrowsError(try AgentAction.parse(#"{"tool":"read_file","arguments":{"path":"../secret"}}"#))
        XCTAssertThrowsError(try AgentAction.parse(#"{"tool":"delete_file","arguments":{}}"#))
        XCTAssertThrowsError(try AgentAction.parse("not JSON"))
        XCTAssertThrowsError(try AgentAction.parse(#"{"tool":"edit_file","arguments":{"content":12}}"#))
        XCTAssertThrowsError(try AgentAction.parse(#"{"tool":"report","arguments":{"text":"done"},"extra":true}"#))
    }
    func testPaidModelRejectedBeforeNetwork() async {
        do {
            _ = try await AgentProvider(provider: "OpenAI", model: "gpt-4.1", paid: false).reply([])
            XCTFail("Paid model accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("free")) }
    }
}

extension AgentTests {
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

extension AgentTests {
    func testEmptyKeyNeverTouchesKeychain() {
        for key in ["", " \n\t"] {
            XCTAssertThrowsError(try AgentKeychain.save(key, provider: "OpenRouter", update: { _, _ in
                XCTFail("Empty save must not update the saved key"); return errSecSuccess
            }, add: { _ in
                XCTFail("Empty save must not create a key"); return errSecSuccess
            }))
        }
    }

    func testKeyReplacementUpdatesInPlace() throws {
        var updates = 0
        try AgentKeychain.save(" replacement-test-value \n", provider: "OpenRouter", update: { query, attributes in
            updates += 1
            let q = query as NSDictionary, values = attributes as NSDictionary
            XCTAssertEqual(q[kSecAttrAccount] as? String, "OpenRouter")
            XCTAssertEqual(values[kSecValueData] as? Data, Data("replacement-test-value".utf8))
            XCTAssertEqual(values[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            return errSecSuccess
        }, add: { _ in
            XCTFail("Existing key must be updated, not re-created"); return errSecSuccess
        })
        XCTAssertEqual(updates, 1)
    }

    func testFailedReplacementDoesNotAttemptAdd() {
        XCTAssertThrowsError(try AgentKeychain.save("test-value", provider: "OpenRouter", update: { _, _ in
            return errSecAuthFailed
        }, add: { _ in
            XCTFail("Update failures must not fall back to replacing the item"); return errSecSuccess
        }))
    }

    func testMissingKeyIsAddedAndAddFailuresReported() throws {
        var additions = 0
        try AgentKeychain.save("test-value", provider: "OpenAI", update: { _, _ in errSecItemNotFound }, add: { entry in
            additions += 1
            let values = entry as NSDictionary
            XCTAssertEqual(values[kSecAttrAccount] as? String, "OpenAI")
            XCTAssertEqual(values[kSecValueData] as? Data, Data("test-value".utf8))
            return errSecSuccess
        })
        XCTAssertEqual(additions, 1)
        XCTAssertThrowsError(try AgentKeychain.save("test-value", provider: "OpenAI",
            update: { _, _ in errSecItemNotFound }, add: { _ in errSecNotAvailable }))
    }
}
