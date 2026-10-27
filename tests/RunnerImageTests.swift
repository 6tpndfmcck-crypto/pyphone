import XCTest
import Combine
import Foundation

final class RunnerImageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PythonBridge.reset()
    }

    override func tearDown() {
        PythonBridge.reset()
        super.tearDown()
    }

    private func marker(_ id: Int) -> String { "\u{001F}PYPHONE_IMAGE:\(id)\u{001E}\n" }

    private func frame(_ value: String) -> String { Data(value.utf8).base64EncodedString() }

    private func image(_ id: Int, revision: Int, data: String?) -> [String: Any] {
        let payload: Any = data.map { $0 as Any } ?? NSNull()
        return ["id": id, "kind": "image", "text": "<HeliOS Image>", "placeholder": "",
                "image_revision": revision, "image_data": payload]
    }

    private func state(_ sequence: Int, images: [[String: Any]], output: String = "") throws {
        let payload: [String: Any] = [
            "widgets": images, "running": false, "prompt": NSNull(),
            "prompt_id": 0, "tid": 0, "seq": sequence, "error_line": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        PythonBridge.setState(try XCTUnwrap(String(data: data, encoding: .utf8)), output: output)
    }

    @MainActor
    private func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard predicate() else {
            XCTFail(message)
            throw NSError(domain: "RunnerImageTests", code: 1)
        }
    }

    @MainActor
    func testImageDeltasKeepIdentityAndDoNotRepublishUnchangedFrames() async throws {
        let first = frame("first frame")
        let output = "before\n" + marker(7) + "after\n"
        try state(10, images: [image(7, revision: 10, data: first)], output: output)
        let runner = Runner()
        try await waitUntil("Initial image did not arrive") { runner.inlineImages.count == 1 }
        XCTAssertEqual(runner.inlineImages.first?.id, 7)
        XCTAssertEqual(runner.inlineImages.first?.image_data, first)
        XCTAssertEqual(runner.output, output)
        XCTAssertEqual(PythonBridge.getStateArguments().first, "-1")

        var publications = 0
        let subscription = runner.$inlineImages.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let imageRevision = runner.imageRevision
        try state(11, images: [image(7, revision: 10, data: nil)])
        try await waitUntil("Numeric delta cursor did not advance") {
            PythonBridge.getStateArguments().contains("11")
        }
        XCTAssertEqual(runner.inlineImages.first?.image_data, first)
        XCTAssertEqual(runner.imageRevision, imageRevision)
        XCTAssertEqual(publications, 0)

        for revision in 12...16 {
            let latest = frame("frame \(revision)")
            try state(revision, images: [image(7, revision: revision, data: latest)])
            try await waitUntil("Updated image did not replace its existing snapshot") {
                runner.inlineImages.first?.image_data == latest
            }
            XCTAssertEqual(runner.inlineImages.count, 1)
            XCTAssertEqual(runner.inlineImages.first?.id, 7)
            XCTAssertEqual(runner.output, output)
        }
    }

    @MainActor
    func testImageSnapshotBeforeMarkerSurvivesDeltaCursor() async throws {
        let data = frame("frame before stdout marker")
        try state(10, images: [image(7, revision: 10, data: data)], output: "before\n")
        let runner = Runner()
        try await waitUntil("First state was not consumed") {
            PythonBridge.getStateArguments().contains("10")
        }
        XCTAssertTrue(runner.inlineImages.isEmpty)
        try state(10, images: [image(7, revision: 10, data: nil)], output: marker(7) + "after\n")
        try await waitUntil("Image bytes were lost before their stdout marker arrived") {
            runner.inlineImages.first?.image_data == data
        }
        XCTAssertEqual(runner.output, "before\n" + marker(7) + "after\n")
    }

    @MainActor
    func testMarkerBeforeImageSnapshotReceivesFrameWithoutNewText() async throws {
        let output = "before\n" + marker(7) + "after\n"
        try state(10, images: [], output: output)
        let runner = Runner()
        try await waitUntil("Image marker was not consumed") { runner.output == output }
        XCTAssertTrue(runner.inlineImages.isEmpty)
        let data = frame("late frame")
        try state(11, images: [image(7, revision: 11, data: data)])
        try await waitUntil("Late image did not refresh unchanged output") {
            runner.inlineImages.first?.image_data == data
        }
        XCTAssertEqual(runner.output, output)
    }

    @MainActor
    func testClearAndTrimReleaseImagesWithoutResurrectingTheirMarkers() async throws {
        try state(10, images: [image(7, revision: 10, data: frame("first"))], output: marker(7))
        let runner = Runner()
        try await waitUntil("Initial image did not arrive") { runner.inlineImages.count == 1 }
        runner.clearOutput()
        try state(11, images: [image(7, revision: 11, data: frame("after clear"))])
        try await waitUntil("Post-clear state was not consumed") {
            PythonBridge.getStateArguments().contains("11")
        }
        XCTAssertTrue(runner.output.isEmpty)
        XCTAssertTrue(runner.inlineImages.isEmpty)

        try state(12, images: [image(8, revision: 12, data: frame("new image"))], output: marker(8))
        try await waitUntil("A newly created image was not displayed after clearing") {
            runner.inlineImages.first?.id == 8
        }
        try state(13, images: [image(8, revision: 12, data: nil)], output: String(repeating: "x", count: 210_000))
        try await waitUntil("Trimmed image was not released") {
            runner.output.hasPrefix("[Older output trimmed]") && runner.inlineImages.isEmpty
        }
        XCTAssertLessThanOrEqual(runner.output.utf16.count, 200_000)
        try state(14, images: [image(8, revision: 14, data: frame("trimmed update"))])
        try await waitUntil("Post-trim state was not consumed") {
            PythonBridge.getStateArguments().contains("14")
        }
        XCTAssertTrue(runner.inlineImages.isEmpty)
        XCTAssertFalse(runner.output.contains("PYPHONE_IMAGE"))
    }

    @MainActor
    func testRetainedImageCountIsBoundedAndExplicitEvictionClearsData() async throws {
        let images = (1...17).map { image($0, revision: 20, data: frame("frame \($0)")) }
        try state(20, images: images, output: (1...17).map(marker).joined())
        let runner = Runner()
        try await waitUntil("Image limit was not applied") { runner.inlineImages.count == 16 }
        XCTAssertEqual(Set(runner.inlineImages.map(\.id)), Set(2...17))

        let delta = (2...17).map { image($0, revision: $0 == 17 ? 21 : 20, data: nil) }
        try state(21, images: delta)
        try await waitUntil("Explicit newer null image revision did not evict data") {
            !runner.inlineImages.contains(where: { $0.id == 17 })
        }
        XCTAssertEqual(runner.inlineImages.count, 15)
        XCTAssertTrue(runner.inlineImages.allSatisfy { $0.image_data != nil })
    }
}
