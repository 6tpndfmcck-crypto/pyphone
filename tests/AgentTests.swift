import XCTest

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
