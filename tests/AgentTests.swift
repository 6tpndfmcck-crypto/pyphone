import XCTest
import Security

final class AgentTests: XCTestCase {
    func testPaidModelRejectedBeforeNetwork() async {
        do {
            _ = try await AgentProvider(provider: "OpenAI", model: "gpt-4.1", paid: false).reply([])
            XCTFail("Paid model accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("free")) }
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
