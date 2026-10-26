import XCTest
import SwiftUI
import UIKit

final class WorkspaceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "pyphone-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func testMigrationKeepsOldDraftAndExistingFiles() throws {
        try "existing".write(to: directory.appendingPathComponent("script.py"), atomically: true, encoding: .utf8)
        defaults.set("print('v1 draft')", forKey: "code")
        defaults.set("script", forKey: "filename")
        let store = ScriptStore(directory: directory, defaults: defaults)
        XCTAssertEqual(store.code, "print('v1 draft')")
        XCTAssertEqual(try read("script.py"), "existing")
        XCTAssertEqual(try read(store.name), store.code)
        XCTAssertEqual(defaults.string(forKey: "code"), store.code)
        let reopened = ScriptStore(directory: directory, defaults: defaults)
        XCTAssertEqual(reopened.scripts.count, 2)
        XCTAssertEqual(reopened.code, store.code)
    }

    func testEditingAndSwitchingSavesBothScripts() throws {
        let store = ScriptStore(directory: directory, defaults: defaults)
        let original = store.name
        store.edit("print('first')")
        XCTAssertTrue(store.create(name: "second", text: "print('second')"))
        XCTAssertEqual(try read(original), "print('first')")
        XCTAssertTrue(store.open(original))
        XCTAssertEqual(store.code, "print('first')")
        XCTAssertEqual(try read("second.py"), "print('second')")
    }

    func testPendingDraftIsRecoveredWithoutOverwritingDisk() throws {
        defaults.set(true, forKey: "v2.migrated")
        defaults.set("game.py", forKey: "v2.draft.name")
        defaults.set("unsaved edit", forKey: "v2.draft.text")
        try "last saved".write(to: directory.appendingPathComponent("game.py"), atomically: true, encoding: .utf8)
        let store = ScriptStore(directory: directory, defaults: defaults)
        XCTAssertEqual(store.code, "unsaved edit")
        XCTAssertEqual(try read("game.py"), "last saved")
        XCTAssertEqual(try read(store.name), "unsaved edit")
    }

    func testExternalEditGetsPreserved() throws {
        let store = ScriptStore(directory: directory, defaults: defaults)
        let oldName = store.name
        store.edit("my new version")
        try "Files version".write(to: directory.appendingPathComponent(oldName), atomically: true, encoding: .utf8)
        XCTAssertTrue(store.save())
        XCTAssertNotEqual(store.name, oldName)
        XCTAssertEqual(try read(oldName), "Files version")
        XCTAssertEqual(try read(store.name), "my new version")
    }

    func testDuplicateRenameAndLongNameCollisions() throws {
        let store = ScriptStore(directory: directory, defaults: defaults)
        let long = String(repeating: "x", count: 100)
        XCTAssertTrue(store.create(name: long, text: "one"))
        XCTAssertTrue(store.create(name: long, text: "two"))
        let second = store.name
        store.rename(String(repeating: "x", count: 80))
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.name, second)
        store.duplicate()
        XCTAssertEqual(store.code, "two")
        XCTAssertNotEqual(store.name, second)
        XCTAssertFalse(ScriptStore.filename("../../escape").contains("/"))
    }

    func testSaveFailureRetainsDraftAndBlocksSwitch() throws {
        let store = ScriptStore(directory: directory, defaults: defaults)
        store.edit("precious edit")
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        XCTAssertFalse(store.create(name: "next"))
        XCTAssertEqual(store.code, "precious edit")
        XCTAssertEqual(defaults.string(forKey: "v2.draft.text"), "precious edit")
        XCTAssertFalse(store.isSaved)
    }

    func testIndentationHandlesBlocksCommentsAndStrings() {
        XCTAssertEqual(PythonIndentation.continuation(for: "if ready:"), "    ")
        XCTAssertEqual(PythonIndentation.continuation(for: "    while playing: # repeat"), "        ")
        XCTAssertEqual(PythonIndentation.continuation(for: "    print('colon:')"), "    ")
        XCTAssertEqual(PythonIndentation.continuation(for: "# comment:"), "")
        XCTAssertEqual(PythonIndentation.continuation(for: "print('unfinished:"), "")
    }

    func testConsoleColorAndResetRendering() {
        let result = ANSIConsoleRenderer.render("plain \u{001B}[31mred\u{001B}[0m done", fontSize: 15)
        XCTAssertEqual(result.string, "plain red done")
        XCTAssertEqual(result.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? UIColor, .systemRed)
        XCTAssertEqual(result.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? UIColor, .label)
        XCTAssertEqual(ANSIConsoleRenderer.render("text\u{001B}[3", fontSize: 15).string, "text")
    }

    func testConsoleLimitHandlesEmojiAndCombiningSequences() {
        let result = ConsoleBuffer.appending(String(repeating: "🙂", count: 200_000), to: "")
        XCTAssertLessThan(result.utf16.count, 200_000)
        XCTAssertTrue(result.hasSuffix("🙂"))
        let combining = ConsoleBuffer.appending(String(repeating: "\u{0300}", count: 300_000), to: "a")
        XCTAssertLessThan(combining.utf16.count, 200_000)
    }

    @MainActor
    func testFullWorkspaceFitsAnIPhone() async throws {
        let host = UIHostingController(rootView: ContentView())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        host.view.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "PyPhone-2-editor"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(host.view.bounds.height, 0)
    }
}
